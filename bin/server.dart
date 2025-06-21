/// Полный код с поддержкой media_group, копирования сообщений, фото, документов и caption'ов
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:googleapis_auth/auth_io.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:http/http.dart' as http;

final botToken = Platform.environment['BOT_TOKEN']!;
final chatId = Platform.environment['CHAT_ID_TEST']!;
final goalChatId = Platform.environment['CHAT_ID_GOAL']!;
final firebaseUrl = Platform.environment['FIREBASE_URL']!;
final webhookSecret = Platform.environment['WEBHOOK_SECRET']!;
final ARCHIVE_CHANNEL = Platform.environment['ARCHIVE_CHANNEL']!;
final ARCHIVE_CHANNEL_GOAL_ID = Platform.environment['ARCHIVE_CHANNEL_GOAL_ID']!;

final allowedChatIds = {int.parse(goalChatId)};
final _mediaGroupCache = <String, List<Map<String, dynamic>>>{};
final _mediaGroupTimers = <String, Timer>{};

Future<String> getAccessToken() async {
  final serviceJson = Platform.environment['Service_Account'];
  if (serviceJson == null) throw Exception('❌ SERVICE_ACCOUNT is not set');
  final credentials = ServiceAccountCredentials.fromJson(jsonDecode(serviceJson));
  final scopes = [
    'https://www.googleapis.com/auth/firebase.database',
    'https://www.googleapis.com/auth/userinfo.email',
  ];
  final client = await clientViaServiceAccount(credentials, scopes);
  final token = client.credentials.accessToken.data;
  client.close();
  return token;
}

Future<void> sendErrorToTelegram(String message) async {
  final uri = Uri.parse('https://api.telegram.org/bot$botToken/sendMessage');
  final res = await http.post(uri, body: {
    'chat_id': chatId,
    'text': message,
  });
  if (res.statusCode != 200) {
    print('⚠️ Telegram error report failed: ${res.body}');
  }
}

Future<void> saveMessageToFirebase(Map<String, dynamic> msg) async {
  final timestamp = DateTime.now();
  final year = '${timestamp.year}';
  final month = '${timestamp.month}'.padLeft(2, '0');
  final day = '${timestamp.day}'.padLeft(2, '0');
  final messageId = msg['message_id'].toString();

  final token = await getAccessToken();
  final baseUrl = '$firebaseUrl/messages/$year/$month/$day/$messageId';
  final url = '$baseUrl.json?access_token=$token';

  final from = msg['from'] ?? {};
  final newEntry = {
    'text': msg['text'] ?? '',
    'from': {
      'id': from['id'],
      'username': from['username'] ?? '',
      'first_name': from['first_name'] ?? '',
    },
    'chat_id': msg['chat']?['id'],
    'timestamp': timestamp.toUtc().toIso8601String(),
  };

  try {
    final getRes = await http.get(Uri.parse(url));
    final exists = getRes.statusCode == 200 && getRes.body != 'null';
    if (!exists) {
      final putRes = await http.put(Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(newEntry),
      );
      if (putRes.statusCode == 200) {
        print('✅ Сохранено как основное сообщение');
      } else {
        throw Exception('Ошибка при сохранении: ${putRes.body}');
      }
    } else {
      final childUrl = '$baseUrl/children.json?access_token=$token';
      final postRes = await http.post(Uri.parse(childUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(newEntry),
      );
      if (postRes.statusCode == 200) {
        print('✅ Добавлено как дочернее сообщение');
      } else {
        throw Exception('Ошибка при добавлении: ${postRes.body}');
      }
    }
  } catch (e) {
    final error = '❗ Firebase save error: $e';
    print(error);
    await sendErrorToTelegram(error);
  }
}

Future<void> copyMessageManually(Map<String, dynamic> msg) async {
  final caption = msg['caption'] ?? '';
  final text = msg['text'] ?? '';

  if (msg.containsKey('media_group_id')) {
    final groupId = msg['media_group_id'];
    _mediaGroupCache[groupId] = _mediaGroupCache[groupId] ?? [];
    _mediaGroupCache[groupId]!.add(msg);

    _mediaGroupTimers[groupId]?.cancel();
    _mediaGroupTimers[groupId] = Timer(const Duration(seconds: 2), () async {
      final group = _mediaGroupCache.remove(groupId);
      _mediaGroupTimers.remove(groupId);
      if (group != null && group.isNotEmpty) {
        final media = group.map((m) {
          if (m.containsKey('photo')) {
            return {
              'type': 'photo',
              'media': m['photo'].last['file_id'],
              if (m['caption'] != null) 'caption': m['caption'],
            };
          } else if (m.containsKey('document')) {
            return {
              'type': 'document',
              'media': m['document']['file_id'],
              if (m['caption'] != null) 'caption': m['caption'],
            };
          }
          return null;
        }).whereType<Map<String, dynamic>>().toList();

        if (media.isNotEmpty) {
          final uri = Uri.parse('https://api.telegram.org/bot$botToken/sendMediaGroup');
          await http.post(uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'chat_id': ARCHIVE_CHANNEL,
                'media': media,
              }));
        }
      }
    });
  } else if (msg.containsKey('photo')) {
    final fileId = msg['photo'].last['file_id'];
    await http.post(
      Uri.parse('https://api.telegram.org/bot$botToken/sendPhoto'),
      body: {
        'chat_id': ARCHIVE_CHANNEL,
        'photo': fileId,
        'caption': caption.isNotEmpty ? caption : text,
      },
    );
  } else if (msg.containsKey('document')) {
    final fileId = msg['document']['file_id'];
    await http.post(
      Uri.parse('https://api.telegram.org/bot$botToken/sendDocument'),
      body: {
        'chat_id': ARCHIVE_CHANNEL,
        'document': fileId,
        'caption': caption.isNotEmpty ? caption : text,
      },
    );
  } else if (text.isNotEmpty) {
    await http.post(
      Uri.parse('https://api.telegram.org/bot$botToken/sendMessage'),
      body: {
        'chat_id': ARCHIVE_CHANNEL,
        'text': text,
      },
    );
  }
}

Future<Response> _webhookHandler(Request request) async {
  if (request.method != 'POST') return Response.forbidden('⛔ Only POST allowed');
  final body = await request.readAsString();
  print('📥 Webhook payload: $body');

  try {
    final data = jsonDecode(body);
    final message = data['message'] ?? data['edited_message'] ?? data['channel_post'] ?? data['edited_channel_post'];
    if (message == null) return Response.ok('Ignored');

    final chatId = message['chat']?['id'];
    if (chatId == null || !allowedChatIds.contains(chatId)) {
      print('🚫 Invalid chat_id: $chatId');
      return Response.forbidden('⛔ Chat not allowed');
    }
    await saveMessageToFirebase(message);
  if(chatId.toString() == ARCHIVE_CHANNEL_GOAL_ID){
    await copyMessageManually(message);
  }
  } catch (e, st) {
    final error = '❗ JSON error: $e\n$st\nBODY:\n$body';
    print(error);
    await sendErrorToTelegram(error);
  }

  return Response.ok('ok');
}

void main() async {
  final router = Router()
    ..post('/webhook/$webhookSecret', _webhookHandler);

  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addHandler(router);

  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);

  print('🚀 Server running at http://localhost:$port');
}
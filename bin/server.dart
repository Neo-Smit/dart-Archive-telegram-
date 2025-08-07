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
final webhookSecret = Platform.environment['WEBHOOK_SECRET']!;
final ARCHIVE_CHANNEL = Platform.environment['ARCHIVE_CHANNEL']!;
final ARCHIVE_CHANNEL_GOAL_ID = Platform.environment['ARCHIVE_CHANNEL_GOAL_ID']!;

final allowedChatIds = {int.parse(goalChatId)};
final _mediaGroupCache = <String, List<Map<String, dynamic>>>{};
final _mediaGroupTimers = <String, Timer>{};


Future<void> sendErrorToTelegram(String message) async {
  final uri = Uri.parse('https://api.telegram.org/bot$botToken/sendMessage');
  final res = await http.post(uri, body: {
    'chat_id': chatId,
    'text': message,
  });
  if (res.statusCode != 200) {
    //print('⚠️ Telegram error report failed: ${res.body}');
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
    _mediaGroupTimers[groupId] = Timer(const Duration(seconds: 3), () async {
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
  print("message was sended in ARCHIVE CHANNELE");
}

Future<Response> _webhookHandler(Request request) async {
  if (request.method != 'POST') return Response.forbidden('⛔ Only POST allowed');
  final body = await request.readAsString();

  try {
    final data = jsonDecode(body);
    final message = data['message'] ?? data['edited_message'] ?? data['channel_post'] ?? data['edited_channel_post'];
    if (message == null) return Response.ok('Ignored');

    final chatId = message['chat']?['id'];
    if (chatId == null) {
      print('🚫 Отсутствует chat_id');
      return Response.ok('⛔ Chat ID is missing');
    }
    if (chatId.toString() == ARCHIVE_CHANNEL_GOAL_ID) {
      Future(() => copyMessageManually(message))
          .catchError((e, st) => sendErrorToTelegram('Copy error: $e\n$st'));
    }
  } catch (e, st) {
    final error = '❗ JSON error: $e\n$st\nBODY:\n$body';
    Future(() => sendErrorToTelegram(error));
    return Response.ok("ok");
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

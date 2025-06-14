import 'dart:convert';
import 'dart:io';

import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import 'myConstants.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';

const firebaseUrl = MyConstants.firebaseUrl; // 👈 Укажи свой URL
const telegramBotToken = MyConstants.botToken; // 👈 Укажи токен бота
const telegramChatId = MyConstants.chat_id_Test; // 👈 Укажи ID группы/канала для ошибок

Future<void> saveMessageToFirebase(Map<String, dynamic> message) async {
  final timestamp = DateTime.now();
  final year = timestamp.year.toString();
  final month = timestamp.month.toString().padLeft(2, '0');
  final day = timestamp.day.toString().padLeft(2, '0');
  final messageId = message['message_id'].toString();

  final token = await getAccessTokenFromServiceAccount();
  final url = '$firebaseUrl$year/$month/$day/$messageId.json?access_token=$token';

  final payload = {
    'text': message['text'],
    'from': {
      'id': message['from']['id'],
      'username': message['from']['username'],
      'first_name': message['from']['first_name'],
    },
    'chat_id': message['chat']['id'],
    'timestamp': timestamp.toIso8601String(),
  };

  try {
    final response = await http.put(
      Uri.parse(url),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );

    if (response.statusCode == 200) {
      print('✅ Message saved to Firebase');
    } else {
      print('❌ Failed to save message. Code: ${response.statusCode}');
      await sendErrorToTelegram('❌ Firebase error: ${response.statusCode}');
    }
  } catch (e) {
    print('❗ Save exception: $e');
    await sendErrorToTelegram('❗ Save exception: $e');
  }
}

Future<void> sendErrorToTelegram(String message) async {
  final uri = Uri.parse(
    'https://api.telegram.org/bot$telegramBotToken/sendMessage',
  );

  final response = await http.post(uri, body: {
    'chat_id': telegramChatId,
    'text': message,
  });

  if (response.statusCode != 200) {
    print('⚠️ Failed to send error to Telegram: ${response.body}');
  }
}

Future<Response> _webhookHandler(Request request) async {
  final body = await request.readAsString();
  print('💬 Telegram Webhook: $body');

  try {
    final data = jsonDecode(body);
    if (data.containsKey('message')) {
      await saveMessageToFirebase(data['message']);
    }
  } catch (e) {
    print('❗ Error parsing/saving: $e');
    await sendErrorToTelegram('❗ JSON parsing error: $e');
  }

  return Response.ok('ok');
}

Future<Map<String, dynamic>> fetchMessagesByDate(
    String year, String month, String day) async {
  final token = await getAccessTokenFromServiceAccount();
  final url = Uri.parse('$firebaseUrl$year/$month/$day.json?access_token=$token');

  try {
    final response = await http.get(url);
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data != null ? Map<String, dynamic>.from(data) : {};
    } else {
      print('❌ Error fetching messages: ${response.statusCode}');
      return {};
    }
  } catch (e) {
    print('❌ Exception while fetching: $e');
    return {};
  }
}

Future<String> getAccessTokenFromServiceAccount() async {
  final envJson = Platform.environment['SERVICE_ACCOUNT'];
  if (envJson == null) throw Exception('SERVICE_ACCOUNT is not set');
  final serviceAccountJson = jsonDecode(envJson);

  final credentials = ServiceAccountCredentials.fromJson(serviceAccountJson);
  final scopes = ['https://www.googleapis.com/auth/firebase.database'];

  final client = await clientViaServiceAccount(credentials, scopes);
  final accessToken = client.credentials.accessToken.data;
  client.close();
  return accessToken;
}

void main() async {
  final router = Router()..post('/webhook', _webhookHandler);

  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addHandler(router);

  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final server = await io.serve(handler, InternetAddress.anyIPv4, port);
  print('🚀 Server running on port $port');

  // Пример чтения всех сообщений за определённую дату
  final messages = await fetchMessagesByDate('2025', '06', '14');
  messages.forEach((id, msg) {
    print('🔸 $id: ${msg['text']}');
  });
}

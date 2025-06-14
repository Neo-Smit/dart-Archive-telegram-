import 'dart:convert';
import 'dart:io';
import 'package:googleapis_auth/auth_io.dart';
import 'package:jose/jose.dart';

import 'myConstants.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';

final firebaseUrl=MyConstants.firebaseUrl;
Future<void> saveMessageToFirebase(Map<String, dynamic> message) async {
  final timestamp = DateTime.now();
  final year = timestamp.year.toString();
  final month = timestamp.month.toString().padLeft(2, '0');
  final day = timestamp.day.toString().padLeft(2, '0');
  final messageId = message['message_id'].toString();
  final token = await getAccessTokenFromServiceAccount();
   // 👈 Укажи свой проект
  final path = '$firebaseUrl$year/$month/$day/$messageId.json?access_token=$token';

  final payload = jsonEncode({
    'text': message['text'],
    'from': {
      'id': message['from']['id'],
      'username': message['from']['username'],
      'first_name': message['from']['first_name'],
    },
    'chat_id': message['chat']['id'],
    'timestamp': timestamp.toIso8601String(),
  });

  final response = await HttpClient()
      .postUrl(Uri.parse(path))
      .then((req) {
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    req.write(payload);
    return req.close();
  });

  if (response.statusCode == 200) {
    print('✅ Message saved to Firebase');
  } else {
    print('❌ Failed to save message. Code: ${response.statusCode}');

  }
}

Future<void> sendErrorToTelegram(String message) async {
  const String botToken = 'YOUR_BOT_TOKEN';
  const String chatId = '-1001234567890'; // замени на ID своего канала

  final Uri uri = Uri.parse(
    'https://api.telegram.org/bot$botToken/sendMessage',
  );

  final response = await http.post(
    uri,
    body: {
      'chat_id': chatId,
      'text': '🚨 Ошибка: $message',
    },
  );

  if (response.statusCode != 200) {
    print('⚠️ Не удалось отправить сообщение об ошибке: ${response.body}');
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
  }

  return Response.ok('ok');
}
Future<Map<String, dynamic>> fetchMessagesByDate(String year, String month, String day) async {
  final formattedMonth = month.padLeft(2, '0');
  final formattedDay = day.padLeft(2, '0');
  final token = await getAccessTokenFromServiceAccount();

  final url = Uri.parse(
    '$firebaseUrl/messages/$year/$formattedMonth/$formattedDay.json?access_token=$token',
  );

  try {
    final response = await http.get(url);

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data == null) {
        print('📭 Нет сообщений за $formattedDay.$formattedMonth.$year');
        return {};
      }

      return Map<String, dynamic>.from(data);
    } else {
      print('❌ Ошибка при чтении (${response.statusCode}): ${response.body}');
      return {};
    }
  } catch (e) {
    print('❌ Исключение при чтении: $e');
    return {};
  }
}
Future<String> getAccessTokenFromServiceAccount() async {
  final serviceAccountJson = jsonDecode(
    await File('serviceAccount.json').readAsString(),
  );

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
  final messages = await fetchMessagesByDate('2025', '06', '14');
  messages.forEach((id, msg) {
    print('🔸 $id: ${msg['text']}');
  });
}

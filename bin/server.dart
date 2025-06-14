import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';

Future<void> saveMessageToFirebase(Map<String, dynamic> message) async {
  final timestamp = DateTime.now();
  final year = timestamp.year.toString();
  final month = timestamp.month.toString().padLeft(2, '0');
  final day = timestamp.day.toString().padLeft(2, '0');
  final messageId = message['message_id'].toString();

  final firebaseUrl = 'https://telegrambotwebhook-bd4cf-default-rtdb.firebaseio.com/'; // 👈 Укажи свой проект
  final path = '$firebaseUrl$year/$month/$day/$messageId.json';

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

void main() async {
  final router = Router()..post('/webhook', _webhookHandler);

  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addHandler(router);

  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final server = await io.serve(handler, InternetAddress.anyIPv4, port);
  print('🚀 Server running on port $port');
}

import 'dart:convert';
import 'dart:io';

import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'myConstants.dart';

const firebaseUrl = MyConstants.firebaseUrl;
const telegramBotToken = MyConstants.botToken;
const telegramChatId = MyConstants.chat_id_Test;

// 🔐 Получение access_token из переменной окружения SERVICE_ACCOUNT
Future<String> getAccessTokenFromServiceAccount() async {
  final envJson = Platform.environment['Service_Account'];
  if (envJson == null) throw Exception('Service_Account is not set');
  final serviceAccountJson = jsonDecode(envJson);
  final credentials = ServiceAccountCredentials.fromJson(serviceAccountJson);

  final scopes = [
    'https://www.googleapis.com/auth/firebase.database',
    'https://www.googleapis.com/auth/userinfo.email',
  ];
  final client = await clientViaServiceAccount(credentials, scopes);
  final accessToken = client.credentials.accessToken.data;
  client.close();
  return accessToken;
}

// 💬 Безопасное сохранение Telegram-сообщения в Firebase
Future<void> saveMessageToFirebase(Map<String, dynamic> message) async {
  final timestamp = DateTime.now();
  final year = timestamp.year.toString();
  final month = timestamp.month.toString().padLeft(2, '0');
  final day = timestamp.day.toString().padLeft(2, '0');
  final messageId = message['message_id']?.toString() ?? 'unknown';

  final token = await getAccessTokenFromServiceAccount();
  final url = '$firebaseUrl/messages/$year/$month/$day/$messageId.json?access_token=$token';

  // Безопасное извлечение "from"
  final from = message['from'];
  final fromMap = from is Map<String, dynamic> ? from : {};

  final payload = {
    'text': message['text']?.toString() ?? '',
    'from': {
      'id': fromMap['id'],
      'username': fromMap['username']?.toString() ?? '',
      'first_name': fromMap['first_name']?.toString() ?? '',
    },
    'chat_id': message['chat']?['id'],
    'timestamp': DateTime.now().toUtc().toIso8601String(),
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
      final errorMsg = '❌ Failed to save message. Code: ${response.statusCode}';
      print(errorMsg);
      await sendErrorToTelegram(errorMsg);
    }
  } catch (e, st) {
    final errorText = '❗ Save exception: $e\n$st';
    print(errorText);
    await sendErrorToTelegram(errorText);
  }
}
// 📩 Отправка ошибок в Telegram
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

// 🔧 Обработка webhook Telegram
Future<Response> _webhookHandler(Request request) async {
  final body = await request.readAsString();
  print('📥 Webhook received:\n$body');

  try {
    final data = jsonDecode(body);

    // Обрабатываем только обычные сообщения
    if (data.containsKey('message')) {
      await saveMessageToFirebase(data['message']);
    } else if(data.containsKey('edit_message')){
      await saveMessageToFirebase(data['edit_message']);
    }else{
      print('⚠️ Игнорируется: не message или edit_)message');
    }

  } catch (e) {
    print('❗ JSON parsing/saving error: $e');
    await sendErrorToTelegram('❗ JSON parsing error: $e\n\n$body');
  }

  return Response.ok('ok');
}
// 📦 Чтение сообщений по дате (например, в консоли)
Future<Map<String, dynamic>> fetchMessagesByDate(String year, String month, String day) async {
  final token = await getAccessTokenFromServiceAccount();
  final url = Uri.parse('$firebaseUrl/messages/$year/$month/$day.json?access_token=$token');

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

void main() async {
  final router = Router()..post('/webhook', _webhookHandler);

  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addHandler(router);

  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final server = await io.serve(handler, InternetAddress.anyIPv4, port);

  print('🚀 Server running on port $port');
}

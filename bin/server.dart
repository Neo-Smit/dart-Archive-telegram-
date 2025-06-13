import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';

Future<Response> _webhookHandler(Request request) async {
  final body = await request.readAsString();
  print('💬 Telegram Webhook: \$body');

  // Здесь можно добавить обработку и сохранение в файл, Hive или другую БД

  return Response.ok('ok');
}

void main() async {
  final router = Router()..post('/webhook', _webhookHandler);

  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addHandler(router);

  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final server = await io.serve(handler, InternetAddress.anyIPv4, port);
  print('🚀 Server running on port \$port');
}
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../config/yandex_config.dart';
import '../l10n/app_strings.dart';

/// Ошибка похода в Yandex Object Storage с реальной причиной (код ответа
/// и тело, либо тип сетевого сбоя) — чтобы AuthProvider мог показать её,
/// а не глушить всё под одной надписью "ошибка сети".
class S3Exception implements Exception {
  S3Exception(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Простой клиент для Yandex Object Storage (S3-совместимое API),
/// подписывающий запросы по AWS Signature V4. Без сторонних SDK —
/// только dio + crypto, чтобы не тащить лишние зависимости.
class YandexS3Client {
  YandexS3Client({Dio? dio}) : _dio = dio ?? Dio();
  final Dio _dio;

  static const _service = 's3';

  /// Возвращает содержимое объекта [key] в виде строки, либо null,
  /// если объекта нет (404).
  Future<String?> getObject(String key) async {
    final res = await _request('GET', key);
    if (res == null) return null;
    return utf8.decode(res.data as List<int>);
  }

  /// true, если объект существует.
  Future<bool> exists(String key) async {
    final res = await _request('HEAD', key);
    return res != null;
  }

  /// Загружает JSON-строку [body] в объект [key].
  Future<void> putObject(String key, String body) async {
    await _request(
      'PUT',
      key,
      body: utf8.encode(body),
      contentType: 'application/json; charset=utf-8',
    );
  }

  /// Возвращает сырые байты объекта [key] (например, аватарку),
  /// либо null, если объекта нет.
  Future<Uint8List?> getBytes(String key) async {
    final res = await _request('GET', key);
    if (res == null) return null;
    return Uint8List.fromList(res.data as List<int>);
  }

  /// Загружает произвольные байты [bytes] (например, изображение аватарки)
  /// в объект [key] с указанным content-type.
  Future<void> putBytes(String key, List<int> bytes, String contentType) async {
    await _request('PUT', key, body: bytes, contentType: contentType);
  }

  Future<Response<dynamic>?> _request(
    String method,
    String key, {
    List<int>? body,
    String? contentType,
  }) async {
    final now = DateTime.now().toUtc();
    final amzDate = _amzDate(now);
    final dateStamp = _dateStamp(now);
    final payload = body ?? const <int>[];
    final payloadHash = sha256.convert(payload).toString();

    final canonicalUri = '/${YandexConfig.bucket}/${_uriEncodePath(key)}';
    const canonicalQuery = '';

    final headers = <String, String>{
      'host': YandexConfig.endpoint,
      'x-amz-content-sha256': payloadHash,
      'x-amz-date': amzDate,
    };
    if (contentType != null) headers['content-type'] = contentType;

    final sortedKeys = headers.keys.toList()..sort();
    final canonicalHeaders =
        sortedKeys.map((k) => '$k:${headers[k]}\n').join();
    final signedHeaders = sortedKeys.join(';');

    final canonicalRequest = [
      method,
      canonicalUri,
      canonicalQuery,
      canonicalHeaders,
      signedHeaders,
      payloadHash,
    ].join('\n');

    final credentialScope =
        '$dateStamp/${YandexConfig.region}/$_service/aws4_request';
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      credentialScope,
      sha256.convert(utf8.encode(canonicalRequest)).toString(),
    ].join('\n');

    final signingKey = _signingKey(dateStamp);
    final signature =
        Hmac(sha256, signingKey).convert(utf8.encode(stringToSign)).toString();

    final authorization = 'AWS4-HMAC-SHA256 '
        'Credential=${YandexConfig.accessKeyId}/$credentialScope, '
        'SignedHeaders=$signedHeaders, '
        'Signature=$signature';

    final url = 'https://${YandexConfig.endpoint}$canonicalUri';
    final reqHeaders = {
      ...headers,
      'Authorization': authorization,
    };

    try {
      final res = await _dio.request<dynamic>(
        url,
        data: body != null ? Uint8List.fromList(body) : null,
        options: Options(
          method: method,
          headers: reqHeaders,
          responseType: ResponseType.bytes,
          validateStatus: (code) => code != null && code < 500,
        ),
      );
      if (res.statusCode == 404) return null;
      if (res.statusCode != null &&
          res.statusCode! >= 200 &&
          res.statusCode! < 300) {
        return res;
      }
      throw S3Exception(
          'Yandex Object Storage error ${res.statusCode}: ${_bodyPreview(res.data)}');
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      final status = e.response?.statusCode;
      final body = e.response?.data;
      if (status != null) {
        throw S3Exception(
            'Yandex Object Storage error $status: ${_bodyPreview(body)}');
      }
      // Настоящая сетевая проблема (нет соединения, DNS, таймаут, TLS)
      // — тут e.type/e.message реально полезны для диагностики.
      throw S3Exception(AppStrings.current.networkError(e.type, e.message));
    }
  }

  String _bodyPreview(Object? data) {
    if (data == null) return '';
    final s = data is List<int> ? utf8.decode(data, allowMalformed: true) : data.toString();
    return s.length > 300 ? '${s.substring(0, 300)}…' : s;
  }

  List<int> _signingKey(String dateStamp) {
    List<int> hmac(List<int> key, String msg) =>
        Hmac(sha256, key).convert(utf8.encode(msg)).bytes;
    final kDate = hmac(utf8.encode('AWS4${YandexConfig.secretAccessKey}'), dateStamp);
    final kRegion = hmac(kDate, YandexConfig.region);
    final kService = hmac(kRegion, _service);
    return hmac(kService, 'aws4_request');
  }

  String _amzDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}${two(d.month)}${two(d.day)}T'
        '${two(d.hour)}${two(d.minute)}${two(d.second)}Z';
  }

  String _dateStamp(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}${two(d.month)}${two(d.day)}';
  }

  /// Кодирует путь по правилам AWS (каждый сегмент отдельно, '/' не трогаем).
  String _uriEncodePath(String path) {
    return path.split('/').map(Uri.encodeComponent).join('/');
  }
}

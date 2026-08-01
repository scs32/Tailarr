import 'package:dio/dio.dart';

/// Fallback (web / unsupported): a brand-new [Dio] already means a fresh
/// transport, and there is no dart:io connection pool to dodge. See the io
/// variant for the B26 rationale.
Future<Response<dynamic>> freshConnectionFetch(RequestOptions options) =>
    Dio().fetch(options);

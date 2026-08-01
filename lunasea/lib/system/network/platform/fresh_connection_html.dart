import 'package:dio/dio.dart';

/// Web has no dart:io HttpClient connection pool to dodge (browser fetch owns
/// connection reuse), so a fresh [Dio] is all the "fresh connection" the B26
/// retry needs here. See the io variant for the full rationale.
Future<Response<dynamic>> freshConnectionFetch(RequestOptions options) =>
    Dio().fetch(options);

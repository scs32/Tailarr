import 'package:dio/dio.dart';

/// Web has no dart:io HttpClient connection pool to dodge (browser fetch owns
/// connection reuse) and the Tailarr Server module is native-only anyway
/// (Tailscale is unsupported on web), so on web this degrades to a plain
/// backoff retry over a fresh [Dio]. See the io variant for the full rationale.
Future<Response<dynamic>> freshConnectionFetch(RequestOptions options) =>
    Dio().fetch(options);

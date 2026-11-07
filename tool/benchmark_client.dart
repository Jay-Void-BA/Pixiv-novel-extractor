// Synthetic transport benchmark; never contacts Pixiv or reads login credentials.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiori/core/models.dart';
import 'package:shiori/core/pixiv_client.dart';

Future<void> main() async {
  const count = 12;
  const latency = Duration(milliseconds: 300);
  var active = 0, peak = 0, requests = 0;
  final transport = MockClient((request) async {
    active++;
    requests++;
    if (active > peak) peak = active;
    await Future<void>.delayed(latency);
    active--;
    return http.Response(
      jsonEncode({
        'error': false,
        'body': {
          'title': request.url.pathSegments.last,
          'userName': 'synthetic',
          'content': 'Synthetic benchmark text',
        },
      }),
      200,
    );
  });
  final clock = Stopwatch()..start();
  // The v1.0.0 extraction loop: serial GETs plus a 700ms delay between chapters.
  for (var i = 1; i <= count; i++) {
    if (i > 1) await Future<void>.delayed(const Duration(milliseconds: 700));
    final response = await transport.get(
      Uri.parse('https://www.pixiv.net/ajax/novel/$i'),
    );
    jsonDecode(response.body);
  }
  final baseline = clock.elapsedMilliseconds;
  final api = PixivClient(transport);
  final work = Work(
    title: 'synthetic',
    author: 'test',
    link: const WorkLink(WorkKind.series, '1'),
    chapters: List.generate(
      count,
      (i) => Chapter(id: '${i + 1}', title: '', order: i + 1),
    ),
  );
  final selection = {for (var i = 1; i <= count; i++) '$i'};
  clock.reset();
  final result = await api.extract(work, selection, cancel: Cancellation());
  final optimized = clock.elapsedMilliseconds;
  if (result.map((n) => n.id).join(',') != selection.join(',') || peak > 3) {
    throw StateError('Benchmark violated order/concurrency guarantees');
  }
  final beforeCache = requests;
  clock.reset();
  await api.extract(work, selection, cancel: Cancellation());
  final cached = clock.elapsedMicroseconds;
  if (requests != beforeCache) {
    throw StateError('Cached extraction made requests');
  }
  api.dispose();
  final report = jsonEncode({
    'kind': 'synthetic; not real Pixiv throughput',
    'chapters': count,
    'latency_ms': latency.inMilliseconds,
    'baseline_serial_700ms_ms': baseline,
    'optimized_ms': optimized,
    'speedup': baseline / optimized,
    'cached_us': cached,
    'cached_network_requests': 0,
    'peak_requests': peak,
    'max_concurrent': 3,
    'start_interval_ms': 350,
  });
  final file = File('build/benchmark-client.json');
  await file.parent.create(recursive: true);
  await file.writeAsString('$report\n');
  stdout.writeln(report);
}

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;

import '../api/mns_client.dart';
import 'app_build_info.dart';
import 'client_policy.dart';
import 'runtime_version.dart';
import 'runtime_version_fetcher_stub.dart' if (dart.library.js_interop) 'runtime_version_fetcher_web.dart' as platform;

typedef DeployedVersionReader = Future<RuntimeReleaseInfo?> Function();

/// Reads the client policy (`GET /public/clients/infragis-mobile/policy`) of an installed app.
typedef ClientPolicyReader = Future<ClientPolicy?> Function();

/// Detects that a newer InfraGIS release went live while the web app stays open.
///
/// It reads the release `build.json` on start, every ~5 minutes while the page is visible and when
/// the page becomes visible again, and accepts a different version only after two reads agree
/// [confirmDelay] apart. It never reloads by itself: the UI shows a notice and the operator updates
/// between field tasks. "Later" is kept in memory only.
///
/// Installed apps update through their store: they read the client policy on start, every
/// [policyInterval] and back in the foreground, and only show a critical notice when the running
/// version is below the minimum of their platform or the API refused it (HTTP 426). A failed read
/// or no minimum changes nothing (fail open).
class AppUpdateController extends ChangeNotifier {
  AppUpdateController({
    DeployedVersionReader? reader,
    ClientPolicyReader? policyReader,
    Future<String?> Function()? apiBase,
    ValueListenable<bool>? unsupported,
    String? runningVersion,
    String? platformName,
    bool? web,
    DateTime Function()? clock,
  })  : _reader = reader ?? (() => platform.fetchLatestRuntimeRelease(appBuildInfo.product)),
        _policyReader = policyReader ?? (() => fetchClientPolicy(apiBase)),
        _unsupportedSignal = unsupported ?? clientVersionUnsupported,
        runningVersion = normalizeVersion(runningVersion ?? appBuildInfo.version),
        web = web ?? kIsWeb,
        _platformName = platformName ?? clientPlatform(web: web),
        _clock = clock ?? DateTime.now;

  static const pollInterval = Duration(minutes: 5);
  static const policyInterval = Duration(hours: 6);
  static const minCheckGap = Duration(minutes: 1);
  static const confirmDelay = Duration(seconds: 45);
  static const snoozeDuration = Duration(hours: 4);

  final DeployedVersionReader _reader;
  final ClientPolicyReader _policyReader;
  final ValueListenable<bool> _unsupportedSignal;
  final String _platformName;
  final DateTime Function() _clock;
  final String runningVersion;

  /// Web build (`build.json` notice); otherwise an installed app (client policy).
  final bool web;

  RuntimeReleaseInfo? _deployed;
  ({String version, DateTime seenAt})? _candidate;
  ({String version, DateTime until})? _snooze;
  DateTime? _lastCheckAt;
  Future<void>? _inFlight;
  Timer? _pollTimer;
  Timer? _confirmTimer;
  ClientPolicy? _policy;
  AppLifecycleListener? _lifecycle;
  bool _started = false;
  bool _disposed = false;

  RuntimeReleaseInfo? get deployed => _deployed;

  /// Version shown on the notice: the deployed web release or the latest installed release.
  String? get noticeVersion => web ? _deployed?.version : _policy?.latest;

  /// Minimum version of this installed platform from the last policy read; null when unset.
  String? get minimumVersion => _policy?.minimum[_platformName];

  bool get updateAvailable {
    final version = _deployed?.version;
    return version != null && version != runningVersion;
  }

  /// The running bundle is below the release `minimumVersion`: the notice cannot be postponed (it
  /// still never reloads by itself).
  bool get critical {
    if (!web) {
      final minimum = minimumVersion;
      return _unsupportedSignal.value || (minimum != null && compareSemver(runningVersion, minimum) < 0);
    }
    final minimum = _deployed?.minimumVersion;
    return minimum != null && updateAvailable && compareSemver(runningVersion, minimum) < 0;
  }

  bool get noticeVisible {
    if (!web) return critical;
    if (!updateAvailable) return false;
    if (critical) return true;
    final snooze = _snooze;
    return snooze == null || snooze.version != _deployed!.version || !snooze.until.isAfter(_clock());
  }

  /// Starts background detection: `build.json` on the web build, the client policy on installed apps.
  void start() {
    if (_started) return;
    _started = true;
    if (!web) {
      _unsupportedSignal.addListener(_onUnsupported);
      _lifecycle = AppLifecycleListener(onResume: () => unawaited(check()));
      _pollTimer = Timer.periodic(policyInterval, (_) => unawaited(check(force: true)));
      unawaited(check(force: true));
      return;
    }
    platform.listenPageVisible(() => unawaited(check()));
    _schedulePoll();
    unawaited(check(force: true));
  }

  void _onUnsupported() {
    if (!_disposed) notifyListeners();
  }

  Future<void> check({bool force = false}) {
    final pending = _inFlight;
    if (pending != null) return pending;
    final now = _clock();
    final last = _lastCheckAt;
    if (!force && last != null && now.difference(last) < minCheckGap) return Future.value();
    _lastCheckAt = now;
    final read = web
        ? _reader().then((build) {
            if (build?.version != null && !_disposed) observe(build!, _clock());
          })
        : _policyReader().then((policy) {
            if (policy != null && !_disposed) observePolicy(policy);
          });
    final future = read
        .catchError((Object _) {})
        .whenComplete(() => _inFlight = null);
    _inFlight = future;
    return future;
  }

  /// Feeds one `build.json` read into the confirmation state.
  @visibleForTesting
  void observe(RuntimeReleaseInfo build, DateTime at) {
    final version = normalizeVersion(build.version);
    if (version.isEmpty) return;
    final current = _deployed;
    if (version == (current?.version ?? runningVersion)) {
      _candidate = null;
      _confirmTimer?.cancel();
      if (current == null || current.minimumVersion != build.minimumVersion) {
        _deployed = RuntimeReleaseInfo(version: version, buildRef: build.buildRef, minimumVersion: build.minimumVersion);
        notifyListeners();
      }
      return;
    }
    final candidate = _candidate;
    if (candidate != null && candidate.version == version) {
      if (at.difference(candidate.seenAt) >= confirmDelay) {
        _candidate = null;
        _confirmTimer?.cancel();
        _deployed = RuntimeReleaseInfo(version: version, buildRef: build.buildRef, minimumVersion: build.minimumVersion);
        notifyListeners();
      }
      return;
    }
    _candidate = (version: version, seenAt: at);
    _confirmTimer?.cancel();
    if (_started) _confirmTimer = Timer(confirmDelay, () => unawaited(check(force: true)));
  }

  /// Feeds one client policy read (installed apps).
  @visibleForTesting
  void observePolicy(ClientPolicy policy) {
    final wasCritical = critical;
    final previous = _policy;
    _policy = policy;
    if (wasCritical != critical || previous?.latest != policy.latest) notifyListeners();
  }

  /// "Later": hide the notice for this version for a few hours (this tab only).
  void postpone() {
    final version = _deployed?.version;
    if (version == null) return;
    _snooze = (version: version, until: _clock().add(snoozeDuration));
    notifyListeners();
  }

  void reloadNow() => platform.reloadPage();

  void _schedulePoll() {
    final jitter = Duration(seconds: Random().nextInt(60) - 30);
    _pollTimer = Timer(pollInterval + jitter, () {
      if (platform.isPageVisible()) unawaited(check());
      if (!_disposed) _schedulePoll();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _confirmTimer?.cancel();
    _lifecycle?.dispose();
    if (_started && !web) _unsupportedSignal.removeListener(_onUnsupported);
    super.dispose();
  }
}

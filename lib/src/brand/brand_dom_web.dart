import 'package:web/web.dart' as web;

/// The tenant favicon replaces the MNSCloud InfraGIS icons of the page.
void applyFavicon(String url) {
  final head = web.document.head;
  if (head == null) return;
  final existing = web.document.querySelectorAll(
    'link[rel="icon"], link[rel="apple-touch-icon"]',
  );
  for (var i = existing.length - 1; i >= 0; i--) {
    (existing.item(i) as web.Element?)?.remove();
  }
  for (final rel in ['icon', 'apple-touch-icon']) {
    final link = web.document.createElement('link') as web.HTMLLinkElement
      ..rel = rel
      ..href = url;
    head.append(link);
  }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:mnscloud_infragis_mobile/src/ui/work_orders.dart';

void main() {
  test('offers the status moves of the API state machine', () {
    expect(allowedTransitions('OPEN'), ['IN_PROGRESS', 'CANCELLED']);
    expect(allowedTransitions('IN_PROGRESS'), ['ON_HOLD', 'DONE', 'CANCELLED']);
    expect(allowedTransitions('DONE'), isEmpty);
    expect(transitionNeedsNote('DONE'), isTrue);
    expect(transitionNeedsNote('ON_HOLD'), isFalse);
  });
}

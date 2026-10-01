/// Shared-bill screens for a Flutter Zcash wallet.
///
/// The screens are where a wallet's own shape belongs, so they live here
/// rather than in `package:splitz_host`. Everything beneath them — the
/// seam, the signing, the sealing, the log, the sync — is generic, and another
/// wallet adopts that and writes its own screens.
///
/// What the specification requires a person be shown is not a matter of taste
/// and is implemented here rather than left to each wallet: a changed pay-to
/// address and a payee with no key of their own before settling (§14.2,
/// §10.7), the rate a request was priced at and who set it (§14.2), a payment
/// that is recorded and not yet confirmed (§10.5), and a request that carries
/// less than the plan (§8.5).
library;

export 'package:splitz_host/splitz_host.dart';

export 'split_words.dart';

export 'screens/activity_screen.dart';
export 'screens/add_expense_screen.dart';
export 'screens/bill_screen.dart';
export 'screens/bills_screen.dart';
export 'screens/new_bill_screen.dart';
export 'screens/payout_for_screen.dart';
export 'screens/payout_screen.dart';
export 'screens/people_screen.dart';
export 'screens/price_bill_screen.dart';
export 'screens/record_payment_screen.dart';
export 'screens/scan_bill_screen.dart';
export 'screens/settle_screen.dart';
export 'screens/share_bill_screen.dart';
export 'screens/splits_navigator.dart';
export 'screens/swap_screen.dart';
export 'screens/splits_scope.dart';
export 'state/splits_controller.dart';
export 'view/naming.dart';

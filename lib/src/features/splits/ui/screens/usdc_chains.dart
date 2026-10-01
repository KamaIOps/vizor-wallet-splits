/// Where USDC can arrive, for any screen that asks someone to pick a chain.
///
/// The chains are read from the swap provider rather than written down here,
/// so a chain it adds or drops is offered or withdrawn without a release.
library;

import 'package:flutter/material.dart';
import 'package:splitz_host/splitz_host.dart' show TradableAsset;
import 'package:zcash_wallet/src/features/address_book/models/address_book_contact.dart';
import 'package:zcash_wallet/src/features/address_book/models/address_format_validator.dart';
import 'package:zcash_wallet/src/features/swap/domain/swap_asset.dart';

import '../state/splits_controller.dart';
import '../view/chrome.dart';
import 'splits_scope.dart';

/// The asset a swap payout is chosen in.
const String usdc = 'USDC';

SwapAsset _asset(String chain) =>
    SwapAsset.live(assetId: '', symbol: usdc, blockchain: chain, decimals: 6);

/// A chain id as a person reads it — `base` is Base, `arb` Arbitrum.
String usdcChainName(String chain) => _asset(chain).chainLabel;

/// Why [address] cannot receive USDC on [chain], or null when it can or the
/// chain is one this wallet has no check for. The swap screen's own check,
/// so an address it would refuse is refused here too.
String? usdcAddressIssue(String chain, String address) {
  final network = AddressBookNetwork.tryFromChainTicker(
    _asset(chain).chainTicker,
  );
  return network == null ? null : addressFormatIssue(network, address);
}

/// One choice per chain the provider delivers USDC on.
///
/// [onUnavailable] is told why when the chains cannot be listed, so the
/// screen can offer something else rather than going dark.
class UsdcChainPicker extends StatefulWidget {
  const UsdcChainPicker({
    super.key,
    required this.picked,
    required this.onPicked,
    required this.onUnavailable,
    this.enabled = true,
    this.belowPicked,
  });

  final String? picked;
  final ValueChanged<String> onPicked;
  final ValueChanged<String> onUnavailable;
  final bool enabled;

  /// Shown directly under the picked chain — the address it needs — so it is
  /// where the person just tapped rather than below every other chain.
  final Widget? belowPicked;

  @override
  State<UsdcChainPicker> createState() => _UsdcChainPickerState();
}

class _UsdcChainPickerState extends State<UsdcChainPicker> {
  List<TradableAsset>? _chains;
  bool _asked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_asked) return;
    _asked = true;
    SplitsScope.read(context)
        .deliverableOn(usdc)
        .then(
          (listed) {
            if (!mounted) return;
            setState(() => _chains = listed);
            if (listed.isEmpty) {
              widget.onUnavailable('the provider listed none');
            }
          },
          onError: (Object e) {
            if (!mounted) return;
            widget.onUnavailable(SplitsController.describe(e));
          },
        );
  }

  @override
  Widget build(BuildContext context) {
    final listed = _chains;
    if (listed == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text('Asking where USDC can arrive…'),
      );
    }
    final picked = widget.picked?.toLowerCase();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Which chain should it arrive on?'),
        for (final a in listed) ...[
          OptionPill(
            key: Key('splits_payout_chain_${a.chain.toLowerCase()}'),
            label: 'USDC on ${usdcChainName(a.chain)}',
            selected: picked == a.chain.toLowerCase(),
            onTap: widget.enabled ? () => widget.onPicked(a.chain) : null,
          ),
          if (picked == a.chain.toLowerCase() && widget.belowPicked != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: widget.belowPicked,
            ),
        ],
      ],
    );
  }
}

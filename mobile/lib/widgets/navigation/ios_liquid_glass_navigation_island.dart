import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _viewType = 'com.inhousesoftware.photos/liquid_glass_tab_bar';
const _channelPrefix = 'com.inhousesoftware.photos/liquid_glass_tab_bar';

/// A floating native iOS tab island.
///
/// UIKit renders the surface with UIGlassEffect on iOS 26 and newer. Older
/// supported iOS versions receive the equivalent adaptive system material.
class IosLiquidGlassNavigationIsland extends StatefulWidget {
  const IosLiquidGlassNavigationIsland({
    required this.selectedIndex,
    required this.destinations,
    required this.onDestinationSelected,
    super.key,
  });

  final int selectedIndex;
  final List<NavigationDestination> destinations;
  final ValueChanged<int> onDestinationSelected;

  @override
  State<IosLiquidGlassNavigationIsland> createState() => _IosLiquidGlassNavigationIslandState();
}

class _IosLiquidGlassNavigationIslandState extends State<IosLiquidGlassNavigationIsland> {
  MethodChannel? _channel;

  Map<String, Object> get _stateArguments => {
    'selectedIndex': widget.selectedIndex,
    'labels': widget.destinations.map((destination) => destination.label).toList(growable: false),
    'enabled': widget.destinations.map((destination) => destination.enabled).toList(growable: false),
  };

  @override
  void didUpdateWidget(covariant IosLiquidGlassNavigationIsland oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldLabels = oldWidget.destinations.map((destination) => destination.label).toList(growable: false);
    final labels = widget.destinations.map((destination) => destination.label).toList(growable: false);
    final oldEnabled = oldWidget.destinations.map((destination) => destination.enabled).toList(growable: false);
    final enabled = widget.destinations.map((destination) => destination.enabled).toList(growable: false);
    if (oldWidget.selectedIndex != widget.selectedIndex ||
        !listEquals(oldLabels, labels) ||
        !listEquals(oldEnabled, enabled)) {
      _sendState();
    }
  }

  Future<void> _onPlatformViewCreated(int viewId) async {
    final channel = MethodChannel('$_channelPrefix/$viewId');
    _channel = channel;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'onSelected' && call.arguments is int) {
        final index = call.arguments as int;
        if (index >= 0 && index < widget.destinations.length && widget.destinations[index].enabled) {
          widget.onDestinationSelected(index);
        }
      }
    });
    await _sendState();
  }

  Future<void> _sendState() async {
    try {
      await _channel?.invokeMethod<void>('setState', _stateArguments);
    } on PlatformException {
      // The platform view can disappear during a route transition. Its next
      // instance receives the complete state through creationParams.
    }
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    _channel = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: SizedBox(
        height: 64,
        child: UiKitView(
          viewType: _viewType,
          creationParams: _stateArguments,
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: _onPlatformViewCreated,
        ),
      ),
    );
  }
}

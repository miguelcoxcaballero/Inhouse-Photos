import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class ImmichLogo extends StatelessWidget {
  final double size;
  final dynamic heroTag;

  const ImmichLogo({super.key, this.size = 100, this.heroTag});

  @override
  Widget build(BuildContext context) {
    final asset = Theme.of(context).brightness == Brightness.dark
        ? 'assets/inhouse-photos-logo.svg'
        : 'assets/inhouse-photos-logo-light.svg';

    return SvgPicture.asset(asset, width: size, height: size, semanticsLabel: 'Inhouse Photos');
  }
}

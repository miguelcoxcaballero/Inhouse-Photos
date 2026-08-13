import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class ImmichLogo extends StatelessWidget {
  final double size;
  final dynamic heroTag;

  const ImmichLogo({super.key, this.size = 100, this.heroTag});

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset('assets/inhouse-photos-logo.svg', width: size, height: size);
  }
}

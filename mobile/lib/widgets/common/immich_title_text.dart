import 'package:flutter/material.dart';

class ImmichTitleText extends StatelessWidget {
  final double fontSize;
  final Color? color;

  const ImmichTitleText({super.key, this.fontSize = 48, this.color});

  @override
  Widget build(BuildContext context) {
    return Text(
      'inhouse photos',
      maxLines: 1,
      style: TextStyle(
        fontFamily: 'Comfortaa',
        fontSize: fontSize,
        fontWeight: FontWeight.w700,
        letterSpacing: -1.2,
        color: color ?? Theme.of(context).colorScheme.primary,
      ),
    );
  }
}

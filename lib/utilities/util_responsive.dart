import 'package:flutter/material.dart';

import '../core/core_layout.dart';

class UtilResponsive {
  UtilResponsive._();

  static bool isCompact(BuildContext context) =>
      MediaQuery.sizeOf(context).width < CoreLayout.compactMaxWidth;
}

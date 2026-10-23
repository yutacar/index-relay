import 'package:flutter/services.dart';

// Distribution assets and native entry points independently enforce the same boundary.
const bool previewMode = appFlavor == 'preview';

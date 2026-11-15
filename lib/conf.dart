import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations_ar.dart';
import 'package:flutter_gen/gen_l10n/app_localizations_en.dart';

import 'logic/language.dart';

const List<int> ports = [50500, 50050];

/// Only Arabic and English are shipped.
List<Language> get languageList => [
      Language(
        name: 'english',
        nameLocal: 'English',
        locale: const Locale('en'),
        localizations: AppLocalizationsEn(),
      ),
      Language(
        name: 'arabic',
        nameLocal: 'العربية',
        locale: const Locale('ar'),
        localizations: AppLocalizationsAr(),
      ),
    ];

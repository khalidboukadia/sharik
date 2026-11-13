import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class SharikLogo extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Material(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset(
              'assets/logo_app.png',
              height: 52,
              semanticLabel: 'SharKhalid app icon',
            ),
            const SizedBox(
              width: 12,
            ),
            Text(
              'SharKhalid',
              style: GoogleFonts.poppins(
                fontSize: 34,
                fontWeight: FontWeight.w600,
              ),
            )
          ],
        ),
      );
}

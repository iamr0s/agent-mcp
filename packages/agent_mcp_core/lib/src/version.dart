import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const String agentMcpVersion = '3.5.2';

const String appIconSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">'
    '<defs>'
    '<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">'
    '<stop offset="0%" stop-color="#161838"/>'
    '<stop offset="100%" stop-color="#090A16"/>'
    '</linearGradient>'
    '<radialGradient id="aura" cx="0.68" cy="0.70" r="0.52">'
    '<stop offset="0%" stop-color="#4F46E5" stop-opacity="0.56"/>'
    '<stop offset="100%" stop-color="#4F46E5" stop-opacity="0"/>'
    '</radialGradient>'
    '<linearGradient id="pBack" x1="0" y1="0" x2="1" y2="1">'
    '<stop offset="0%" stop-color="#939EFF"/>'
    '<stop offset="100%" stop-color="#4F46E5"/>'
    '</linearGradient>'
    '<linearGradient id="pFront" x1="0" y1="0" x2="1" y2="1">'
    '<stop offset="0%" stop-color="#FFFFFF"/>'
    '<stop offset="100%" stop-color="#DFE6FF"/>'
    '</linearGradient>'
    '</defs>'
    '<rect x="2" y="2" width="60" height="60" rx="15" fill="url(#bg)" stroke="#818CF8" stroke-opacity="0.28" stroke-width="1"/>'
    '<rect x="2" y="2" width="60" height="60" rx="15" fill="url(#aura)"/>'
    '<path fill="url(#pBack)" fill-rule="evenodd" d="M35.6 18.2a3.2 3.2 0 0 1 4.5 0l12.7 12.7a3.2 3.2 0 0 1 0 4.5L40.1 48.1a3.2 3.2 0 0 1-4.5 0L22.9 35.4a3.2 3.2 0 0 1 0-4.5Z M36.6 26.2a1.8 1.8 0 0 1 2.5 0l5.7 5.7a1.8 1.8 0 0 1 0 2.5l-5.7 5.7a1.8 1.8 0 0 1-2.5 0l-5.7-5.7a1.8 1.8 0 0 1 0-2.5Z"/>'
    '<path fill="url(#pFront)" fill-rule="evenodd" d="M26.9 11.4a3.4 3.4 0 0 1 4.8 0l13.9 13.9a3.4 3.4 0 0 1 0 4.8L31.7 44.0a3.4 3.4 0 0 1-4.8 0L13.0 30.1a3.4 3.4 0 0 1 0-4.8Z M28.0 19.9a1.9 1.9 0 0 1 2.6 0l6.3 6.3a1.9 1.9 0 0 1 0 2.6l-6.3 6.3a1.9 1.9 0 0 1-2.6 0l-6.3-6.3a1.9 1.9 0 0 1 0-2.6Z"/>'
    '</svg>';

final String appIconDataUri =
    'data:image/svg+xml;base64,${base64Encode(utf8.encode(appIconSvg))}';

/// Exact 64x64 RGBA Concentric Liquid Prism PNG (synced by `scripts/sync_brand_icons.py`).
/// Satisfies the MCP `icons` specification mandatory (`MUST`) `image/png` MIME requirement.
const String appIconPng64Base64 = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAZl0lEQVR42rWbeXBdV53nP79z7lslWZZkyUsc4zh2FtuQDegkTWOzNVsFGBgFeooCkjBptu5qhpkpqAEcd0M3gTCTLkgghAwEMlSwaIZqIN1J08QmhNDTkMaJrSzO5tghliVLsvQkveWe85s/7n13eU9OgKJl37rLu8v57d/f7/yO8Fv/qezadY0ABmDvXhgZGdexsa0KuxVQ/n3/BBBGR2XH8a3SvrhzJ3737t/++/Kb3jc6uscAjI1d7k55k4AxljAMLWAPHUKmpo6YqSkrs6XJ9FsTz/2xCWDF0rAODDjt7T3db9iAbtuGC4LAee9RPTWNo6OjNhrnmP9NmPG8DBgd3WOzRP/saa3c+c2/3zIzNbm1tlDf3GjWN7QardWtMBwIQ9frvS+r90XnfaCqVr0aVW9UQVHQiACvKuoVVFFU1SvxEaq+fd2j6hQ8SiiiTUTqIlIzYmasDSZsofh0uVQ+VO3tf+jSl7zs0Ec+culSlhljY2Pud2SACruuEXbv9gcOHCjeevv+N0wdP/EfT86c/MP52sLGZtPRaLRotVqEYYhzDvUeHxOIarrnFPvcsc9dB59/Ho3kKQoIRgRjDDawBDbABpZSqfJUT7Xvp5WeFX93yUsvuGP37subsMs8l2kuywBVFRFRgP/6sa+/89izUx+dOD69bfrESRYXaoRhCOCMERUxiIjEJiCZd7SPQJHnJj4an8bMyzBAIybE1/HRPV5Vifca4tULqlaMpVSq0FPto2/FyoO9fQOf+fE/XXdbItCIe8/NgDbxX/zi3b0HH33klsNPPXv54cNHaNTrLggsxhoRMaZNW/fzpIQnjND4/6mIzxCeENo+97Fp+MyzvltTonu8c6F6HxIEJTs4tIaVAyN7Tluz6qqxsd215ZggHaOXXddcI8PDO6u/OnDgzkcfOXzp0aNHwlKpaIwJTBfvJHPcQXhOCxKCWUbqMXGd9p9hRKoBmePkmRwD4u8r3nsfthq+f+XqYHjktHs3rF/7urExFjvNweYc3vg2e+ONH/LrN170rUcePvLao0ePNqvVSgExqXaLEKs90T8T7SW/RbfGT7WvZ8JF+yw2HojfRu48ZXT6dMe5ZH+RRAtFEGsDs7hwsumcPyMM5axnjv7PPaOjo3Z8fLybAW1v/5GPfe0dTz7x7CeeePzxVrVaKXpPTJBkBh4d02ZEjvB48JlzaQ/4VIQnz5F5P3kmQMLY5c5F8uEYBFXFBoFdWJhrBYXSC8/Z+upH/vGOrz2YZYJkdfjAAQqfuvbaAw/uf2Sz96GKWJMSnw6ucyDL+lLVjFXExzm17zjOqXzGISb2fgrVz/mIDn+R+BLvRYysWbvxsbM2v2n72NjlrfbIDMDonj0GRP/3bbe+bnpqbkujUffGWJPXOklUOSLYpKqd3RIJmshUEIyxBEEUqiS+bq3F2gBrA0Tid2GQ5L3t5w1g0nMxsWZE2kfmPDpO30FsnkascWHTLy7Utjwzce/rAB0dHTUAAQBjEZ0nJqffcWJ6Vq21qnSqbV79JYNKO+GgxNIWEzFlcaHOUr2BNUKpFH2y2WzSaLQIAku1WiawAc65OGIIikckDaWqIGjyubZTbV9TPKImigoimWMD6jHG6tJiTZdqJ98B/H0eV4Pe/eST5ev/262HHnnoifXGiEfERM7N5O00Y8epDXdHAxsYFhYaNBtNzjlnPTt3vJALzt/MmrWDWGuYmZnn4YcOs+8n+7nvvoMsLTXp7+8jgrppGOxU+U5VT6OGz0eNjmNUvaqawaF1R176ktefdeutV9QBCUZH95ixscvd3m/94qzF2tJpzoVqbdEsK90M6Z3OK3FMsdSnp+c55+zTeP/73shr//giSqVCl5v4w0u3cdVVb+BX+x/nS1/6Hj/4wX1UKhVKpSJhGCa+RlXb/j3hsWTyAY01JdpFUu88VlHjXVPDVnP9kSOPngU8MDo6aszWrQcFYGpqemuj6QTw3fE+75lPRbwxBu+VublFrrzij/nOnv/Bmy67mEKxQLPlaTY9zZan0VTqTc9S3VNvKOefdyY3ffkj3HDDX1CtBszNzVMIgvg7sd1nfEJi7xk/077WPqd9ngux4p33srAwtxXg+PGtErTJXFxY2tJsNBGR2P5T+vJxtnOLfgmModEMAeW6z17JW958CarQbHmMMZg2eIxiNKoCNjpfrHtU4S1vfhnbt5/J+9//OQ4ceIrBwUHC0EV2npU0AuoT2BUpiibpQiQrH/uSWJnVI2LUOUcYtra06TZ790YHjaXmhmarFUlW03xoOdCYi7kIgbXUGyHFUsBXbvoz3vLmS2i2HM4rNiY8BoARTuvYtxk0t+DYdOZavr3nr7j00u1MTU4RBDbWBJuTfj4qdESK3Hlb+gaRAO8czrVOjwa1FzMyEgGCVtgaie1Onj9nSjXAWstSvUm1WuSWm/+cSy4+h0bTYW008E6CEyllmRBvgbXUFjw9PT3ceuvHecUrL2Ty+BRBzhxsSmBCpF2WEbnzGK967wm9Xw2wb9+ImrGxsYgBLTfgnXueEkHeMVpjqNebVKslbv7Kn3P+eZtoND2BtSmxy0k9y5COvTWGesNjgyJfveVjvPJVF2Y0IUu0AbFAqhlZwrPXsowAUOcHoi+OqQFURHAu7PXeI6KSz+qWyfo0UttmM6RUCrj5pj/jvBdtjIk3p5S6KjiveK94v7w5aPzuRlMxpsBXvvoxXr7jPE5MnYiYkAAmmxLYdohZottbIntBxEgkAN+bRYJqjME7LXvvO3JazdOvJBjcuSgG3/CFD3D+eWfEam+6JJsQHkbvrpaFclkwFpzTLgalTBAaTcXaAjfd/FEuuHALMzOzsWnl7f2UjGjjmEQLIu31SjnWhggKh2FovXdF1YwnzRGdvy4i1GqLfPpT7+bii8+m3ohsXk+h8qHzVCuR+u1/8EkOjj9LrdagrxqFVud1WXMwRqg3POVqmRtv+ijr1q1kcWEhjiidobA7RHZqRRvUoRS//W1nUygM1qsPUI1gZFKCkqiEkOGGNZaZmXmuuvK1vPlNf0Cj6VKbzxBOFHnw6umpGH54x0+5/vpvomaYlYPrWNFXYeeOrbz1P7yYQsHSaCjGSM5Btk1toeZYf/oA1173F7znnZ/E+3Ji+21Hm3Pd7YcxaSBTje/3KBIcPHjQAs4AHDqEeK82W3tLipiZQoYRYXGpwdlnn8Z/+fBbCUNFxLTvSolX8B68Oqplw7Wf/Rrvec8nsaVNbNryUgaHXoCYEb73/cf5zGd/xPx8nVJJcC7z7YwG2cAyPe3YuXMr777yMk6cmMQGWY9vE0dHZ5gkC5RigKSY6emnhXZtf2oK472a1ASyhpkmHojQqDf40AffRLVaJHSKiHTZsVfw3lEtW3Zd82WuvfYbvOYN7+ScbZfQ27eOwaFNDK/ezObNL+LpI4bPff4eTs7VKRYF5zNWl40O1nBy3nP1+0c5c/MZLMzPxaYguVCYxQFZhrTNIc5g7bFjNZNhwK8FVRORqpLWMtNSlhhhcbHOueeezmtefRGtUDHGdIU3AO89PRXLtZ/9Ol/4wu288S1XsGbduZTLw6zoP42enhGqlWHK5WHWr9/M1FSZ6//25ywttbB2+ZAJQrMBw8NVrnzvVdigH+fqGAnSMNdh7ykQSuBxZOCKWRoopxowW5qUdlZFrnqbxjERYWmxzs6d51EqWcIwjRA5hxfGNv8P93Hddd/gdZe9m+HVWyiXh+jpWUWx0IMxJYwpEtgK1vaxZu0LOHJE+OZt+wkC8B1Osb2JERoN5aKXbGD7C19LtTpC6BoYCTpCn+lgSlrGa0eDlYuzKQPSD7VtUNPqTfs377FWOP+8zXnCs4An9tyLSy2u/1/f4MWXvJ41686iVBqgUhnE2sh5pZIVRAJEKqxffyYHDoQ8+ugcpbIkTMg5RYRWSxhZXWVgsMimTa+np7oK51s5qCwZGJzFA5AyoT05FTNgdVJNTUpVaI4R3ntKpYDVqwdyzjYrfe+Vcll49LFnwI6w8YztGFOlXBnA2iJolC2qj+51oceaIoEtM39yml8ffZpf/OvjFAKWBUoAzkGlWqRScXgvnHPOWwlsJfLyYtM6JXkHKOQ1oP0XhcGJiY46XbvSkl6L5AXGmgQWd8VuooEbU2Zw1emIFCiVVmBNTLy2iY+AURCUmZ0+xv7772L2xFEmJ4/z0pdYjLkgHo90YQPVNCGrL80xOLCRTZtez6OPfhdri0gyk9SuH7THL6AGEc1VNRIT8F4lpwEZhkTchUajyexMLUZTugyuF5otWLNmgBUrqnhvMBKgavBKRvKOQqHCxLNPcs+Pb2Ny4jBBoUSx2MPW7WcS+u5EKSFeoNn0zM8tImJo1GuMrLqAwcGtONfIRANJNCH1Cd1FHpOr4mpG9TNM0NgJNhpNHn74cAxyFDozPKDVUoaGSuz4o3M5ebKGqsM5h3dxDhBL/tivn+Dn94wRhiGVSi/zc0ucfc56drxiGws1zdUPSMKrYi1MTdY4PjFPIShEeMN71q19GcYUM2SlROf/5U0g4wTzk5pZ6atGPiAILPv23Y9XQJYPgSLCwqJy2WUv4uwtK5mYOI53TVzo8M5jbIHZ6Qn+373fxXtPoVCk2WhSKBg++om3Ue0pEIbLJ0reKaUSPLj/MHOzTYJCCQgIwyY9ldPo630B3ocp5E3mLzJb+/pEFwPiyL+M9FHFO0dPT5X77nuQXz3wFNUycULUHbOdE6yxvO9P/4CRVZ7jE8fwvoFzDhd69t9/F43GEsViiVYzpNUK+avP/AkXvvh0avM+Kcp0mpiIUG/Aj+48QLHYi6EEavEucmd9vWfE9cO2CeRzBMmW97o0gO7Jxk6zMMawtNTixhv2YIzgVZd1UiLQaCq9PSU++IGLGFnV4pmjz6DeMz31NLMnjlKpVKnNLeK9468/9ye8+rXnMDsTlc86YXUbX/T2CT+5+2EOPvAsK1YMAWlY9c5TKq7CGJvOWyxTwpPn8gG5Of2M9NvAyDnHypUr+OEP7uW73/sZK/sszZbLJ0GazeSU3t4SH/zQBVxwfpGZ6QmefupxpqZOMH1iljPOHOKLN13Jq15zLjPTPkqnl0mPvVeKRWFyss7Xb76banWQwPZhTBnURs7VeYyU4rzgVPXLbicY5HxAWwtEM+GkHQLbmiBUqz3s+viNbNu2iU2b1jBfyww+oxEmRm6FIODd79nO44/Nc/8v4cILX8W5W8/g5a/YRrUnYHY2fT4PfKK8QlUpFA1f+PwdTDzbYs2ajVjTh5Ei6iPQJALOteIkUEDz0tZ2lVelGwdMkEF/CeE+KqZKvhASAaIys7Mn+cD7/prb9/wNPT09LNW7maBJ8QTCEM7Y1MdZZ2/D2G14B7Ua1GqKseaUZTLvPP0rDV/+wl5+svcx1q7ZgjUrsbYHNIgBmMeI0GjMoHgMBRSXL+OrREimo+JniBuSIi/g0zl48i0u6SxN5Pz6+/s5ePAwV7/30zRbTYpFk+YHy0gSgXpdOXlSmT7hmZ31EWiKs0nV7kpSGEbEf+sb/8Ltt/2ckeEXUAgGKQT9CEVUJUWWzrGweCSp++U8fn6OGYBSaUkTBgwMuKTxhKQtpRsOZxsYQucZGlrFz+59kKuv+jTOtSgWhTDUbhCT8eLGCNaaBFGeqkLsQs/KAcOeb/2Cm2+4m1VDp1MqDlMIBjGmEnl/H4VGKLBUn2ShfiQyi2XbgSS1BBVfqQykDOjtPd2LxyVzcJyqXSXrHKNBrhoeYe+Pf8nVV32KMGGCzxO3TI1wudJZ2+ad8/THxH/pb3/E4OB6yqU1FApDserbGFlG+AS1TM/+Gz5Ggs/bGCe4+flenzBgw4ZIm/KdXB0Tj+kkY8oEwIXK8Mga9t59P//5ir+k3qhTqRhaLdct2Y5yV6fqO6+o10jtb/2XhPhKeQ3FwhCB6Y3tXlCvOOcRyszXnmCuNo4xpXjMz9MhqPi+vlqqAdu24VBCTSCxz5tADhj5TJ9OzASnDA+v5qf3PMC7/tPHmZg4Qf/KKET6DGQ+ldRVoRV6gkCo9gg3ffFuvnrj3QwNnU6lvJZiYZjA9gGFhHjvPKIBrdY8x0/cfSpCl2/gEglHR0ddwoAgCJygzWVNoLNxKdO9lSLHKE1dtWqEB/c/yTve9t+5Z98DrFplsVZohT7N7zObVyUMPV5hRb+hVlvkLz/+d9z+zX9l1fBGyuW1FAurCGxvB/GKqsF5x7OTd9IKZxEJWFb02YJlOytEm29/u0kYIN57VKQumXCYtJrgc5LPzr1nf28zYWBgiBNTi7z33dew+5O3MF+r0b/SUCxJPCmaSqJQEFb0G4pF+Oc7D/Lh99/KffccYc2aMykX11IqDBMEyxEvqBeOTd7FUv3pVPWzaXBm0263WI/HLEE01a5qRGqIoN5phKN8NLOaAUHRRHv73Le5Gc3ExjjbeahWV+Bci6/c+H/50V33864r3sWLX3omq1f3UamWkpT2+K9PcmD/Yf75rgMcfOAY1eoAq1dvILADFIL+yNsTLEO84djUXdQWD2FMGdUwqWMk0D0D4zKaoXFRJMrp2SUBo6PC2BjGmBkjglMfV3qj4oGqj2jTDKJSSX9rx1z1cYS18YxvgdVr1jNx7ASf/8zNnLttJwODFarVqP4/P7fI5MQ8J0+2KBV7GRnZTBD0E9gVWNtOdAw+Y/OqJpL81D8xv/Aw1pTxGmbUe5kJySwbVNt1gplo4OMS7Di+VfYB1gYTxtikPbVNoIhJ4HH6Qp/SrdmeCkHEx8wzeC/09Aziwjq/PvorCsErmZuBen0eYyoUi/2ctq6CSBkjFYypYiRKcUmKKJG3RwO8d0xM3cX8wqGYeJcr3yVALhljyow40Ys0QGQCYMeOTIOEtfaItRb1DoyJiMdExZC2yseaoBmMLDHxKmnTQqRB7TkDIQh6WFqa4/Dhn3DWWZcxNLSFRqOGekEoAAWEINIeb2J4G8Fg7xVDiWY4z7HJu1isH8GaUky8T3qGiEN0tqs0YkgcvmMmiRgM8nRXMhQUioeCIMCrF5NUNxRRH3fYmoS7qQ9ou4G8FuQ0Ih5KEFSoL80zfvC7nLHxNQwPn493Shg2I9+qkpTMNJ49hgAjllrtSY6fuJtmeBJjipHaZ1pjuzXAL1NL82jEcTCFxxK62w0SK3r6x21gNZow1SRDREyMY31G+iQePVIL36EZqXuMD9DIzPA+5NBj3+fE9GOsW3Mp1co6sEEkbfExhI+c8FJ9kpmT/8Zc7aE4uyxEDi+TqSadYl0a4DNbgmcMeC2KHY8aJMY1iFdWsH37pY8+8dTDzxhj16t6D2La9t+260T67Wgg7cQpqwyShFvJzijHMDdqkiwyPf0Qs7OP0dezgb7ejRSLQxgp4XyLRmOWxcUjLCwdxfsGxpTiOmSYITxbvPE5tJq01Welj/cixojYIyuGtj0aN0j4IO6atLt3v6J+6R+9755SqfKOer3mjQlMVF6KwqHgU+kvhzST3+R51qlEg7emAAhz809wcv7xuJprE80TMRgpYkwRjZ1dtv0+zVo7+wRTvEKWGd55G5TEmuI9+/ZdUW+vJolzx1EA+qorb69W+8Q7J+357Wx6nMsRyOYHPtfImJOGehSHqov30bNeQ1QdYgpYW8KYQky0xZoSRgooHu9b0bPR6pnkXcTX6LreqQVtB+jE2oLYQun2rorQ2NjlHpCLL77wH09MTxyanSlu9t5FKqPtZsOMM0wAUaf6d/qHvLZIDphkIoymbbgqAnT0KmWbIslO2+Wlj+YJT5jtQ29MYIwxh1T77wSkbfrtmqCOju4xu3df3lyxcvCTg0NrJQybLvvBbBd3IvEOrUg3t8w+u/lUWl2/LbOR3seyv3ffFxHv4pJ+6IrFPikEvZ8YH9/djBulNbdeYHx8TEdHR+0Pv//VB7dsefl25/wLFxdPNgMb2BySFsn3Ckp2EcMyHfRdHfXZaatu3H7KLQl5bY/faZ6dah+ZpHONZqnUXwyC0nceeuSGXZ0ryXLVg/HxcWCXufjijXe0fH2HC90Zi4uzoTEWI0bSDlJ5vtUCnWtxOgszyyYt6Tzeb8qA7n1q86F3vuVKpf5CoVi51wSrRycnd4bj4zfq86waiyx9dHRX79Fnpm6ZnTl++czsBGHYdNYEiLEitBdSZDo02t2YZLoxSCcnyN2TWW+APGf/cY6Jue6VPBaIHZ1X9ep9C2MKtljqxQblPcasump8/DdZNNXBBICX7fjwOxfmZz+6UDu5bXGpRqtVR70HxIlYjcKXSNyRIVkGJE2LIgK/KQOWtZfO1h2NU3JNEB7egsHaAsYWsLZw0AaVvxkfv/7//FbL5vK/7RLY7a+++heFRx751htri/Nvqy8tvKzZrG90Lpou894RrfqMAWPyynQVCLl1B9kVHtI1gSHSOSzpHrB0rkuKWuPF2KcCW/ypLVS+UyxuueOXv/zT1u+0cLJzLW7WaXz4w3sq+/cf3FKvz57baDW2uNBt8C5c7b0f8EqvespAUZUgasoRqyqGrpnZ7o7zbLVeVFWjJgUnilc0RKSpSt0INcXMGJEJjH3aEhyyxeChUmnVoZ///CO/r6WznYunR+PF08/zQjF8+9vOzsxgDhz4B3PsWM0sDZSl3ZPTtX76FAupS6UlrVQGdH6+12/YMOJnXn2R/87bjXuuhdMx2XZ09Pe4eHq5Z3bt2iV797YxxF727RtRGFOevx77e1o+v0tgXHbsSJfP79uH/12W7/9/lgoFsB9OElMAAAAASUVORK5CYII=';

final Uint8List appIconPng64Bytes = base64Decode(appIconPng64Base64);

const String appIconPngDataUri = 'data:image/png;base64,$appIconPng64Base64';

/// Builds the full MCP-spec-compliant `icons` array (`2025-11-25` SEP-973 & `2026-07-28`).
List<Map<String, dynamic>> buildMcpServerIcons({String? baseUrl}) {
  final cleanBase = (baseUrl ?? '').trim().replaceAll(RegExp(r'/+$'), '');
  return <Map<String, dynamic>>[
    if (cleanBase.isNotEmpty) ...[
      {
        'src': '$cleanBase/icon-192.png',
        'mimeType': 'image/png',
        'sizes': const ['192x192'],
      },
      {
        'src': '$cleanBase/icon-64.png',
        'mimeType': 'image/png',
        'sizes': const ['64x64'],
      },
    ],
    if (appIconPng64Base64.isNotEmpty) ...[
      {
        'src': appIconPngDataUri,
        'mimeType': 'image/png',
        'sizes': const ['64x64'],
      },
      {
        'src': appIconPngDataUri,
        'mimeType': 'image/png',
        'sizes': const ['64x64'],
        'theme': 'dark',
      },
      {
        'src': appIconPngDataUri,
        'mimeType': 'image/png',
        'sizes': const ['64x64'],
        'theme': 'light',
      },
    ],
    {
      'src': appIconDataUri,
      'mimeType': 'image/svg+xml',
      'sizes': const ['any'],
    },
  ];
}

/// Converts an arbitrary human display name into a strict MCP `Implementation.name` slug.
String sanitizeMcpMachineName(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return 'agent-mcp';
  final slug = trimmed
      .replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (slug.isNotEmpty && RegExp(r'[a-zA-Z0-9]').hasMatch(slug)) {
    return slug.length > 64 ? slug.substring(0, 64) : slug;
  }
  final h6 = sha256.convert(utf8.encode(trimmed)).toString().substring(0, 6);
  return 'agent-mcp-$h6';
}

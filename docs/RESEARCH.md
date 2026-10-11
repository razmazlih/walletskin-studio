# How the artwork sites apply designs

Investigated 2026-10-09:

- https://aircards.org/en/guide/ provides PNG artwork and directs macOS users to install AirCard, connect/trust USB, scan, activate a card in Apple Pay, select artwork, Flash Skins, then force-close/reopen Wallet.
- https://cardart.cc/guide/aircard-mac describes the same native AirCard workflow. Its page does not implement browser-based payment-card modification.
- Primary source: https://github.com/Mak5er/AirCard . WalletSkin uses the already reviewed/pinned commit `52ba05dca4bdc590672c19d554701f4438e20338`, not downloaded release binaries or an unverified website service.

The native method uses AirLift's AirTraffic/ATAirlock synchronization behavior. It writes three artwork assets for the selected `.pkpass` and invalidates that card's rendered caches. It also temporarily stages generated files under Media/Airlock and snapshots/replaces/restores fixed Books sync metadata. There is no public Apple payment-card artwork editing API here. The mechanism is unofficial and a newer OS can patch it.

The original WalletSkin build disabled modification because an artwork-only-path restriction excluded this required staging. After the user's explicit request to enable the same application flow, the release adds tightly constrained staging and per-operation confirmation explaining those writes. It does not claim a reliable original-artwork backup, and it does not attempt a new exploit on patched versions. Actual visibility must be checked by the user on the exact selected card.

#!/bin/bash
# Compile Aura et assemble Aura.app sans Xcode (Command Line Tools uniquement).
#   ./build.sh              compile et assemble ./Aura.app
#   ./build.sh --install    copie dans ~/Applications et lance l'app
#   ./build.sh --clean      supprime .build après coup (libère le disque)
#   ./build.sh --test       lance l'autotest des règles de validation puis s'arrête
#   ./build.sh --cert       crée une fois l'identité de signature « Aura Dev »
set -euo pipefail

cd "$(dirname "$0")"

INSTALL=0
CLEAN=0
TEST=0
CERT=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --clean)   CLEAN=1 ;;
    --test)    TEST=1 ;;
    --cert)    CERT=1 ;;
    -h|--help)
      echo "Usage : ./build.sh [--install] [--clean] [--test] [--cert]"
      exit 0
      ;;
    *)
      echo "Option inconnue : $arg" >&2
      exit 2
      ;;
  esac
done

APP="Aura.app"
# Identité de signature. Sans elle, signature ad-hoc : macOS voit une app différente
# à chaque compilation et oublie les autorisations (Accessibilité, Disque, Écran).
IDENTITY="${AURA_IDENTITY:-Aura Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

has_identity() {
  security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"
}

# --cert : certificat auto-signé de signature de code, valable 10 ans, dans le trousseau
# de session. À lancer une seule fois. macOS peut demander le mot de passe de session.
if [ "$CERT" -eq 1 ]; then
  if has_identity; then
    echo "L'identité « $IDENTITY » existe déjà."
    exit 0
  fi
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  echo "==> Création du certificat « $IDENTITY »"
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$TMP/aura.key" -out "$TMP/aura.crt" \
    -subj "/CN=$IDENTITY" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
  # Mot de passe jetable : `security import` refuse un PKCS#12 sans mot de passe.
  PASS="aura-$RANDOM"
  openssl pkcs12 -export -legacy -out "$TMP/aura.p12" \
    -inkey "$TMP/aura.key" -in "$TMP/aura.crt" -passout "pass:$PASS" 2>/dev/null
  security import "$TMP/aura.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign -A
  # Faire confiance au certificat pour la signature de code (trousseau de session,
  # pas le trousseau système : pas besoin de sudo).
  security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/aura.crt" || true

  if has_identity; then
    echo "Identité prête. Recompile avec ./build.sh --install --clean."
    echo "Le premier build signé change l'identité d'Aura : il faut réaccorder les"
    echo "autorisations UNE dernière fois, elles tiendront ensuite."
  else
    cat <<'MANUEL'
La création automatique a échoué. À faire à la main, une fois (2 min) :
  1. Ouvre Trousseau d'accès.
  2. Menu Trousseau d'accès > Assistant de certification > Créer un certificat…
  3. Nom : Aura Dev · Type d'identité : Racine auto-signée · Type : Signature de code.
  4. Valide, puis double-clique le certificat > Se fier > Signature de code : Toujours approuver.
MANUEL
    exit 1
  fi
  exit 0
fi

echo "==> Compilation (release)"
# swiftc direct : pas besoin de SwiftPM (souvent cassé dans les Command Line Tools)
BIN_DIR=".build/release"
mkdir -p "$BIN_DIR"
find Sources/Aura -name '*.swift' -print0 | xargs -0 swiftc \
  -O -parse-as-library -swift-version 5 \
  -target arm64-apple-macos14.0 \
  -module-name Aura \
  -o "$BIN_DIR/Aura"

# --test : l'autotest tourne sur le binaire nu, sans fenêtre ni installation.
if [ "$TEST" -eq 1 ]; then
  echo "==> Autotest"
  "$BIN_DIR/Aura" --selftest
  if [ "$CLEAN" -eq 1 ]; then
    rm -rf .build
  fi
  exit 0
fi

echo "==> Assemblage de $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Aura" "$APP/Contents/MacOS/Aura"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/hook.sh "$APP/Contents/Resources/hook.sh"
cp Resources/aura "$APP/Contents/Resources/aura"
chmod 755 "$APP/Contents/MacOS/Aura" "$APP/Contents/Resources/hook.sh" "$APP/Contents/Resources/aura"

if has_identity; then
  echo "==> Signature avec « $IDENTITY » (les autorisations tiennent)"
  codesign --force --deep -s "$IDENTITY" "$APP"
else
  echo "==> Signature ad-hoc"
  codesign --force --deep -s - "$APP"
  echo "    Les autorisations d'Aura seront perdues à ce build."
  echo "    Pour qu'elles tiennent : ./build.sh --cert (une seule fois)."
fi

if [ "$INSTALL" -eq 1 ]; then
  DEST="$HOME/Applications"
  echo "==> Installation dans $DEST"
  pkill -x Aura 2>/dev/null || true
  mkdir -p "$DEST"
  rm -rf "$DEST/$APP"
  cp -R "$APP" "$DEST/$APP"
  rm -rf "$APP"
  open "$DEST/$APP"
  echo "Aura est lancée : cherche son icône dans la barre de menus."
else
  echo "App prête : $(pwd)/$APP"
fi

if [ "$CLEAN" -eq 1 ]; then
  echo "==> Nettoyage de .build"
  rm -rf .build
fi

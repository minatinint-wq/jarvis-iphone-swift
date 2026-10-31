#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Abra este projeto em um Mac com Xcode completo instalado."
  exit 1
fi
xcodebuild -project JarvisPhone.xcodeproj -scheme JarvisPhone \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build CODE_SIGNING_ALLOWED=NO build
echo "Build concluído. Para os testes, escolha um simulador iPhone instalado e execute:"
echo 'xcodebuild -project JarvisPhone.xcodeproj -scheme JarvisPhone -destination "platform=iOS Simulator,name=NOME_DO_IPHONE" CODE_SIGNING_ALLOWED=NO test'

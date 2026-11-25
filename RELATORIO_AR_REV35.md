# Revisão 35 — estado do botão dos óculos na câmera

Fonte do aplicativo: 15d4be5bd50b5cab60cad3a33fd12910db94b65b. Compilação e pacote arm64: execução 45523971709 aprovada. SHA-256 do pacote pessoal: e196a088bcb69bbb5eb68f7dfefbf55aa8ca7dd7edd4c719ba4e41de74578607.

O usuário rejeitou a revisão 34: mesmo instalada e verificada, ela continuou mostrando uma imagem contínua. A validação isolada do vídeo não cobria a passagem do estado do SwiftUI para a câmera.

O adaptador WallCameraView recebia apenas uma referência constante a WallARController; não observava o objeto nem recebia o valor do modo. Agora recebe explicitamente headset como Bool e aplica esse valor em makeUIView e updateUIView. O controlador, a sessão, o renderizador, os gestos e os demais módulos foram mantidos.

O teste testHeadsetTogglePropagatesThroughSwiftUIWithoutDirectConfigureCalls monta a interface em UIHostingController, altera o estado observado e verifica o número de olhos na vista real: zero, dois e zero. Ele não chama configure diretamente. Execução 45524298573 aprovada.

O IPA original foi validado. O pacote pessoal preserva os 21 recursos visuais anteriores, nove mapas e 362 arquivos espaciais, conferidos por hash. Instalação concluída e consultada no serviço do iOS: JARVIS 1.2.0 build 35 / VERIFIED_JARVIS_BUILD=35. Teste físico confirmado pelo usuário após tocar no ícone dos óculos: “Sim, agora dividiu”. A divisão da câmera em duas vistas foi aceita. O retorno à vista única foi validado pelo teste automático; não houve nova confirmação física dos demais gestos nesta etapa.

Referência: https://developer.apple.com/documentation/swiftui/uiviewrepresentable/updateuiview(_:context:).

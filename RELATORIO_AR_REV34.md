# Revisão 34 — Holo Comandos e controle do PC em AR/VR

Fonte do aplicativo: eb45b3eb7839e4e4001e4bd35da5f698fd3b81e4. Pacote arm64 e extensão: execução 45514913511 aprovada. IPA original validado; pacote pessoal preserva 21 recursos visuais, nove mapas e 362 arquivos espaciais conferidos por hash. SHA-256 pessoal: 253015b7200a3220a37de59d1a20c65d5217a4f47c1f9cc6c78f1773e29d3635.

## Vídeo do visor

Referência local inspecionada: D:/iPhone-Apps/HoloComandos-2026-11-20/Sources/HoloComandos/StereoRendererView.swift. O projeto original foi preservado.

O Jarvis agora usa dois contêineres físicos opacos e recortados, cada um com uma AVSampleBufferDisplayLayer própria, como no Holo Comandos. Um único ARFrame alimenta as duas camadas. Não há uma segunda captura da câmera nem uma segunda ARSession. A câmera continua independente da recuperação do mapa ou da aquisição de drawables do cenário.

O cenário é renderizado uma vez e copiado pela GPU para duas superfícies transparentes sobre o vídeo. Ossos e cursor continuam compartilhando o mesmo processamento Vision. A faixa central é preta. O cabeçalho único e a mira central foram retirados do modo óculos. A saída restaura a visualização normal e mantém a sessão e os dados do mapa.

O vídeo é monocular duplicado. Não foram implementadas disparidade binocular, correção de distorção ou calibração individual das lentes do VR Box. A aparência e a estabilidade precisam de teste no aparelho e no suporte.

## Entrada do computador

Indicador parado por dois segundos clica; deslocar o indicador reinicia o tempo. Indicador e médio estendidos rolam por eventos de roda do mouse, sem clique. Pinça de uma mão move a janela; duas pinças redimensionam pela separação entre as mãos. Dois dedos na tela fazem zoom no modo sem visor.

O teclado QWERTY é uma parte projetada da janela do PC, com Shift, números, símbolos, Tab, espaço, apagar e Enter. O indicador permanece cerca de 0,55 s na tecla. Três dedos estendidos ou o botão do cabeçalho abrem e recolhem o teclado. O texto entra numa fila; erros descartam ações pendentes para evitar repetição incerta.

A ponte consulta somente metadados de foco e editabilidade do Windows para abrir o teclado automaticamente após clicar num campo compatível. Não lê conteúdo, nomes ou senhas do campo. Aplicativos que não expõem editabilidade usam abertura manual. As mudanças e sete testes Python da ponte estão em bridge-updates/vr34; o helper ativo usa o arquivo fonte atualizado ao iniciar uma nova sessão.

## Validação

A execução 45512395862 validou nove casos dos controles e gerou a captura do teclado projetado, que foi aberta e inspecionada. A execução inicial do teste novo, 45514923764, falhou ao compilar a checagem isReadyForDisplay por falta da guarda de iOS 17.4; nenhum teste de apresentação rodou nessa execução.

A correção está em 8d1bd7f0f24d90d19de296e5f3dab05a38f01f70 e não altera JarvisPhone, Support ou WakeWidget em relação ao pacote eb45b3e. Na execução 45516197127 passaram sete casos funcionais de sessão, comandos, teclado, scroll, clique e escala. O caso novo chegou às duas camadas prontas para apresentar, mas falhou em seguida porque XCUIScreen não é autorizado num teste unitário hospedado. A execução ficou vermelha; não é apresentada como oito testes aprovados. A captura 1×1 produzida nessa falha foi descartada como evidência.

A verificação de apresentação foi então executada em um aplicativo mínimo para iOS, extraindo da fonte as classes de vídeo e o método real displayCamera, sem recompilar ou alterar o app distribuído. A execução 45518048372 foi aprovada: cada camada apresentou 40 quadros, os buffers efetivamente exibidos eram idênticos e os dois contêineres tinham recorte ativo. O próprio simctl capturou a tela desse aplicativo; a imagem foi aberta e inspecionada, mostrando duas sequências completas de quatro cores separadas por faixa preta. É um teste de vídeo sintético, não uma captura do quarto nem prova da composição completa de câmera, mãos e mundo no iPhone físico.

O teste unitário foi corrigido para comparar displayedPixelBuffer e anexar imagens dos quadros exibidos, sem solicitar privilégios de UI testing. Essa alteração dos testes não exigiu gerar outro pacote do aplicativo. O probe fica em scripts/video-presentation-probe.py e é acionado pelo input video_probe de xtool-phone.yml.

Instalação concluída no iPhone 13 Pro Max e verificada pelo serviço do iOS: JARVIS 1.2.0 build 34 / VERIFIED_JARVIS_BUILD=34. O pacote foi assinado e provisionado pelo xtool; a consulta de versão ocorreu após a instalação. A aceitação física da divisão da câmera e dos gestos permanece pendente do teste do usuário. O resultado de câmera contínua da revisão 33 foi preservado no relatório anterior.

## Escopo restante

Não foram implementados nesta entrega o escaneamento RoomPlan da casa nem geração de mundos com Google Genie. Não houve chamada paga ou envio de captura do ambiente ao Google. Não foi comprovada equivalência de rastreamento com Meta Quest ou Apple Vision.

Referência de exibição: https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer e https://developer.apple.com/documentation/coremedia/kcmsampleattachmentkey_displayimmediately.

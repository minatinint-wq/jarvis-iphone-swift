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

A correção está em 8d1bd7f0f24d90d19de296e5f3dab05a38f01f70 e não altera JarvisPhone, Support ou WakeWidget em relação ao pacote eb45b3e. A execução 45516197127 verifica a apresentação das duas camadas reais de vídeo, restauração da sessão, teclado, scroll, clique, escala e comandos. Resultado ainda pendente.

Instalação da revisão 34 e aceitação física ainda pendentes. O iOS confirmou anteriormente a revisão 33; sua câmera ficou contínua e esse resultado foi registrado no relatório anterior.

## Escopo restante

Não foram implementados nesta entrega o escaneamento RoomPlan da casa nem geração de mundos com Google Genie. Não houve chamada paga ou envio de captura do ambiente ao Google. Não foi comprovada equivalência de rastreamento com Meta Quest ou Apple Vision.

Referência de exibição: https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer e https://developer.apple.com/documentation/coremedia/kcmsampleattachmentkey_displayimmediately.

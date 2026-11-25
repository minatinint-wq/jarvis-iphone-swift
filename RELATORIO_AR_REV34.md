# RevisÃ£o 34 â€” Holo Comandos e controle do PC em AR/VR

Fonte do aplicativo: eb45b3eb7839e4e4001e4bd35da5f698fd3b81e4. Pacote arm64 e extensÃ£o: execuÃ§Ã£o 45514913511 aprovada. IPA original validado; pacote pessoal preserva 21 recursos visuais, nove mapas e 362 arquivos espaciais conferidos por hash. SHA-256 pessoal: 253015b7200a3220a37de59d1a20c65d5217a4f47c1f9cc6c78f1773e29d3635.

## VÃ­deo do visor

ReferÃªncia local inspecionada: D:/iPhone-Apps/HoloComandos-2026-11-20/Sources/HoloComandos/StereoRendererView.swift. O projeto original foi preservado.

O Jarvis agora usa dois contÃªineres fÃ­sicos opacos e recortados, cada um com uma AVSampleBufferDisplayLayer prÃ³pria, como no Holo Comandos. Um Ãºnico ARFrame alimenta as duas camadas. NÃ£o hÃ¡ uma segunda captura da cÃ¢mera nem uma segunda ARSession. A cÃ¢mera continua independente da recuperaÃ§Ã£o do mapa ou da aquisiÃ§Ã£o de drawables do cenÃ¡rio.

O cenÃ¡rio Ã© renderizado uma vez e copiado pela GPU para duas superfÃ­cies transparentes sobre o vÃ­deo. Ossos e cursor continuam compartilhando o mesmo processamento Vision. A faixa central Ã© preta. O cabeÃ§alho Ãºnico e a mira central foram retirados do modo Ã³culos. A saÃ­da restaura a visualizaÃ§Ã£o normal e mantÃ©m a sessÃ£o e os dados do mapa.

O vÃ­deo Ã© monocular duplicado. NÃ£o foram implementadas disparidade binocular, correÃ§Ã£o de distorÃ§Ã£o ou calibraÃ§Ã£o individual das lentes do VR Box. A aparÃªncia e a estabilidade precisam de teste no aparelho e no suporte.

## Entrada do computador

Indicador parado por dois segundos clica; deslocar o indicador reinicia o tempo. Indicador e mÃ©dio estendidos rolam por eventos de roda do mouse, sem clique. PinÃ§a de uma mÃ£o move a janela; duas pinÃ§as redimensionam pela separaÃ§Ã£o entre as mÃ£os. Dois dedos na tela fazem zoom no modo sem visor.

O teclado QWERTY Ã© uma parte projetada da janela do PC, com Shift, nÃºmeros, sÃ­mbolos, Tab, espaÃ§o, apagar e Enter. O indicador permanece cerca de 0,55 s na tecla. TrÃªs dedos estendidos ou o botÃ£o do cabeÃ§alho abrem e recolhem o teclado. O texto entra numa fila; erros descartam aÃ§Ãµes pendentes para evitar repetiÃ§Ã£o incerta.

A ponte consulta somente metadados de foco e editabilidade do Windows para abrir o teclado automaticamente apÃ³s clicar num campo compatÃ­vel. NÃ£o lÃª conteÃºdo, nomes ou senhas do campo. Aplicativos que nÃ£o expÃµem editabilidade usam abertura manual. As mudanÃ§as e sete testes Python da ponte estÃ£o em bridge-updates/vr34; o helper ativo usa o arquivo fonte atualizado ao iniciar uma nova sessÃ£o.

## ValidaÃ§Ã£o

A execuÃ§Ã£o 45512395862 validou nove casos dos controles e gerou a captura do teclado projetado, que foi aberta e inspecionada. A execuÃ§Ã£o inicial do teste novo, 45514923764, falhou ao compilar a checagem isReadyForDisplay por falta da guarda de iOS 17.4; nenhum teste de apresentaÃ§Ã£o rodou nessa execuÃ§Ã£o.

A correÃ§Ã£o estÃ¡ em 8d1bd7f0f24d90d19de296e5f3dab05a38f01f70 e nÃ£o altera JarvisPhone, Support ou WakeWidget em relaÃ§Ã£o ao pacote eb45b3e. Na execuÃ§Ã£o 45516197127 passaram sete casos funcionais de sessÃ£o, comandos, teclado, scroll, clique e escala. O caso novo chegou Ã s duas camadas prontas para apresentar, mas falhou em seguida porque XCUIScreen nÃ£o Ã© autorizado num teste unitÃ¡rio hospedado. A execuÃ§Ã£o ficou vermelha; nÃ£o Ã© apresentada como oito testes aprovados. A captura 1Ã—1 produzida nessa falha foi descartada como evidÃªncia.

A verificaÃ§Ã£o de apresentaÃ§Ã£o foi entÃ£o executada em um aplicativo mÃ­nimo para iOS, extraindo da fonte as classes de vÃ­deo e o mÃ©todo real displayCamera, sem recompilar ou alterar o app distribuÃ­do. A execuÃ§Ã£o 45518048372 foi aprovada: cada camada apresentou 40 quadros, os buffers efetivamente exibidos eram idÃªnticos e os dois contÃªineres tinham recorte ativo. O prÃ³prio simctl capturou a tela desse aplicativo; a imagem foi aberta e inspecionada, mostrando duas sequÃªncias completas de quatro cores separadas por faixa preta. Ã‰ um teste de vÃ­deo sintÃ©tico, nÃ£o uma captura do quarto nem prova da composiÃ§Ã£o completa de cÃ¢mera, mÃ£os e mundo no iPhone fÃ­sico.

O teste unitÃ¡rio foi corrigido para comparar displayedPixelBuffer e anexar imagens dos quadros exibidos, sem solicitar privilÃ©gios de UI testing. Essa alteraÃ§Ã£o dos testes nÃ£o exigiu gerar outro pacote do aplicativo. O probe fica em scripts/video-presentation-probe.py e Ã© acionado pelo input video_probe de xtool-phone.yml.

InstalaÃ§Ã£o da revisÃ£o 34 e aceitaÃ§Ã£o fÃ­sica ainda pendentes. O iOS confirmou anteriormente a revisÃ£o 33; sua cÃ¢mera ficou contÃ­nua e esse resultado foi registrado no relatÃ³rio anterior.

## Escopo restante

NÃ£o foram implementados nesta entrega o escaneamento RoomPlan da casa nem geraÃ§Ã£o de mundos com Google Genie. NÃ£o houve chamada paga ou envio de captura do ambiente ao Google. NÃ£o foi comprovada equivalÃªncia de rastreamento com Meta Quest ou Apple Vision.

ReferÃªncia de exibiÃ§Ã£o: https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer e https://developer.apple.com/documentation/coremedia/kcmsampleattachmentkey_displayimmediately.

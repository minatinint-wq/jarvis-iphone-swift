# JARVIS AR — revisão 29

Retorno posterior do usuário: a mão começou funcionando e voltou a ficar lenta. A revisão 29 não foi aprovada no teste físico sustentado; a revisão 30 desliga a coleta contínua do ambiente para investigar essa concorrência. Não foi obtida medição de FPS do aparelho.

Instalação 1.2.0 (29) confirmada pelo serviço da Apple. Código 38350312154a758453dc813aa0e998500d33a085, workflow 45300746833 aprovado. A revisão 28 teve falha física relatada pelo usuário: a mão começou a ser detectada e depois deixou de aparecer. Não foi considerada aprovada.

## Mão e ambiente mais estáveis

- Oscilações de referências ou movimento da câmera têm tolerância de até 1,2 segundo quando o ambiente já estava estável. Interrupção, relocalização real e perdas longas continuam invalidando as referências. A mão não é zerada junto com cada oscilação do mundo.
- Apoios já confirmados ficam em cache durante a continuidade da sessão. Retomar o app ou perder a posição de verdade exige nova confirmação. A malha de oclusão é atualizada com intervalo maior enquanto há uma mão reconhecida.
- A entrada do Vision é reduzida preservando o aspecto, com lado maior de até 640 pixels. A amostragem fica em 10 Hz, ou menor sob aquecimento; a cena continua com sua meta independente de renderização.
- Ossos podem ser desenhados com reconhecimento parcial, sem depender da ponta do indicador. Limiares: pontos 0,18; cursor 0,28; pinça 0,35. Resultados atrasados não executam controles. Há cancelamento de uma solicitação excessivamente demorada e nova solicitação após seu término.
- Uma ausência de até 250 ms durante uma pinça pausa a ação sem perder imediatamente o alvo. Não arrasta usando um ponto antigo. Perdas maiores cancelam. O clique por indicador continua exigindo mais de dois segundos.

## Zoom na pinça

Segure a pinça sobre o painel, tela do PC ou objeto 3D. Aproxime a mão da câmera para ampliar e afaste para reduzir. Movimentos laterais continuam arrastando. Soltar fixa a posição. Profundidade é usada quando disponível; caso contrário, o tamanho aparente da palma fornece uma estimativa com filtro e zona morta. Giro da mão pode afetar essa alternativa; não é medida métrica. Os limites de escala e espaço livre continuam valendo.

O X do menu grande e o botão pequeno Ferramentas, os personagens animados com origem corrigida, o mapa recuperável e a seleção condicional de 0,5× continuam incluídos.

## Validação

O workflow 45300746833 executou os testes direcionados do código de gestos e do Vision, compilou arm64, empacotou a extensão e conferiu os recursos. A suíte completa do simulador não foi repetida nesta revisão. A base do núcleo passou em 76 testes na revisão 26; os resultados não são apresentados como uma nova execução integral da 29.

Testes direcionados: continuidade breve versus perda real/prolongada, preservação do alvo, pausa/cancelamento de pinça, zoom por profundidade e por tamanho aparente, e entrada real do Apple Vision. Seis casos de imagem públicos do MediaPipe foram processados: indicador e polegar para cima, em versões normais e escurecidas, foram reconhecidos; a imagem de gatos/cães, nos dois níveis, retornou zero mãos. Latências observadas no Mac do teste foram 562 ms na primeira inferência e 49–68 ms nas seguintes. Não são medições de latência do iPhone.

Fontes das imagens de teste: assets públicos usados pelos testes oficiais de google-ai-edge/mediapipe. Não são fotos do usuário e não são distribuídas dentro do app. A leitura direta do diagnóstico pelo contêiner do iPhone retornou ApplicationLookupFailed; não foi obtida medição de desempenho desse aparelho por esse caminho.

Confirmação de instalação: `VERIFIED_JARVIS_BUILD=29`. O pacote pessoal preserva 21 recursos visuais e confere nove mapas de materiais e 362 arquivos de modelos. A validação física da nova sensibilidade, do zoom e da retomada do ambiente ainda depende do teste no iPhone; não foi marcada como aprovada.

Arquivos: Core/SpatialGesture.swift, Core/WallARCommand.swift e novo Core/HandPoseInput.swift; Views/SpatialHands.swift, SpatialPanel.swift, SpatialDesktop.swift, SpatialWorld.swift e WallARStudio.swift; registro do projeto, versão, workflows e scripts dos testes. Guias e evidências anteriores permanecem disponíveis.

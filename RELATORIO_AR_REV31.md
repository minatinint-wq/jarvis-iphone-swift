# JARVIS AR — revisão 31

Código: f33254f. Pacote xtool: execução 45493417180. Suíte integral: 45494408086, fonte de testes af42e1b. As árvores de aplicativo, testes, recursos, extensão e projeto são idênticas às do pacote f33254f; somente a configuração de CI mudou. Instalação confirmada pelo próprio iOS: JARVIS 1.2.0 build 31 / VERIFIED_JARVIS_BUILD=31. Aceitação física de gestos, estabilidade e visor pendente.

## Entrega

O usuário relatou afastamento e retorno do painel com e sem a mão. A revisão 30 não foi aprovada no uso físico. Foi encontrada mudança de escala por palma aberta no código; a deriva sem mãos não foi reproduzida nem medida neste computador.

- Palma aberta não redimensiona painel, desktop ou objetos. O gesto de trazer uma janela desenquadrada de volta permanece.
- A pinça usa uma origem fixa, filtro temporal, zona morta e limite de velocidade. Não troca entre profundidade métrica e largura da palma durante a mesma pinça. Giro da mão ainda afeta a estimativa visual.
- Descontinuidades grandes da pose bloqueiam interação até estabilizar. A pose da cabeça não recebe suavização artificial. Isso não resolve deriva lenta nem garante referência física correta.
- Interação exige rastreamento normal. Recuperar sem apagar retoma a sessão sem resetTracking/removeExistingAnchors. Novo mapa continua explícito; o formato de câmera fica estável até troca de lente.
- Malha, profundidade contínua e segmentação permanecem desligadas no perfil Ambiente fixo. A leitura manual de 8 segundos continua disponível.
- Um CADisplayLink consulta currentFrame da mesma sessão como caminho de segurança. O timestamp impede processar o mesmo quadro duas vezes entre esse caminho e o callback. Ler âncoras já rastreadas não reinicia reconstrução do ambiente.
- Pausa, interrupção, encerramento e limite térmico desligam isPlaying e rendersContinuously. O visor secundário acompanha pausa e FPS da vista principal.

## Modo limpo e menu radial

O olho riscado no próprio cabeçalho projetado recolhe barras, menu de cenários/medir/pintar e ossos. Resta um pequeno ícone ancorado. O cursor e o progresso de clique continuam disponíveis; a detecção da mão permanece ativa.

Indicador por mais de dois segundos no ícone abre seis módulos ao redor dele. Setas percorrem os demais módulos, incluindo Tela do PC e Mostrar interface. A identidade do botão central permanece a mesma após renderizar: segurar o dedo não abre e fecha repetidamente. Soltar e fazer outro clique recolhe. Mão aberta é livre; pinça arrasta. A área vazia ao redor do ícone não intercepta a interação dos objetos.

## Visor VR Box experimental

O aplicativo aceita horizontal. Duas ARSCNView compartilham ARSession, cena e ponto de vista, com uma única detecção de mãos. Não há segunda captura nem cópia de framebuffer para a CPU pelo aplicativo. A saída devolve o viewport principal sem trocar seu mapa.

É passagem de vídeo monocular em duas vistas iguais, sem profundidade binocular e sem correção óptica calibrada para as lentes do VR Box. Não equivale a um Quest. Navegador/YouTube em janela de tela ainda não estão adaptados para duas lentes. É necessário testar a abertura da câmera, a fusão da imagem, o campo visual, o aquecimento e o conforto no suporte real.

Entrada: óculos no topo ou “Jarvis, ativar VR Box”. Saída: Sair VR ou “sair do VR Box”. O iOS pode exigir desativar o bloqueio de rotação. A câmera traseira deve ficar livre.

## Validação e limites

A base 999958b passou nos 81 testes XCTest, sem falhas, na execução 45491871032; a etapa posterior de lançamento foi cancelada pela nova execução com o modo limpo. A compilação xtool dessa base terminou com sucesso em 45491876560.

Os novos testes do modo limpo verificam o botão projetado, ícone único, espera completa de dois segundos, abertura única enquanto mantém o dedo, recolhimento depois de soltar, mão livre e passagem de um botão para outro. A suíte final executou 83 testes com zero falhas, incluindo os dois novos casos de modo limpo e mudança de alvo. A compilação xtool/arm64 e o empacotamento com extensão passaram. O processo demorou na finalização do resultado depois de concluir os testes e foi cancelado; o workflow ficou cancelado e a exportação das novas capturas não ficou disponível. A captura positiva anterior das duas vistas foi inspecionada; a revisão visual do radial no aparelho permanece pendente. Não foi declarado workflow integral verde.

As imagens são cenas sintéticas, sem câmera ou LiDAR real. Nos testes anteriores, identidade do delegate do ARKit não se mostrou um sinal observável confiável: o SDK expõe um proxy. A verificação atual exercita a entrada de âncoras usada pelo caminho currentFrame; não inventa callbacks físicos da câmera no simulador. A câmera de teste usa zNear 0,01 m, pois o padrão 1 m escondia o painel a 0,9 m.

Teste físico ainda necessário: dois minutos sem mãos; palma aberta e pinça; sair e voltar no mesmo cômodo; recuperar sem apagar; ícone e radial; visor com ambos os lados atualizando. Não há medição de FPS do iPhone nem aprovação física desta revisão.

Referências técnicas: https://developer.apple.com/documentation/scenekit/scnview/renderscontinuously e https://developer.apple.com/documentation/scenekit/scncamera/znear .

O IPA original passou em scripts/check-ipa.py --with-extension. O pacote personalizado preserva 21 recursos visuais anteriores: ele é validado pelo manifesto da preparação, conferindo as substituições e os hashes de 9 mapas e 362 arquivos espaciais. O validador do IPA original compara a malha com a fonte e não se aplica sem adaptação à malha pessoal preservada.

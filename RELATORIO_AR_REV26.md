# JARVIS AR — revisão 26

Problema observado no aparelho: a revisão 25 recuperou a posição ao retornar do aplicativo e os gestos voltaram a funcionar, conforme confirmação do usuário. No teste posterior de fechar e abrir, a recuperação ficou indefinida. Esse caso não está aprovado.

## Recuperação do mapa

Tentativa de relocalização permanece explícita, preservando coordenadas antigas. O reset solicitado permanece pendente se o app vai para segundo plano durante a troca de mapa, sendo aplicado ao retornar. Após 20 segundos sem rastreamento ou sem as âncoras restauradas, apresenta recuperação com orientação, nova tentativa, escolha de mapa salvo e criação de novo mapa com confirmação. O último mapa é guardado antes de iniciar outro. Mapas ilegíveis também dão acesso à recuperação. Gravações em andamento são invalidadas por geração e serializadas para não sobrescrever um mapa recém-trocado.

Não há reposicionamento silencioso dos objetos na frente da câmera. Arquivos de mapas não são garantia de relocalização: iluminação, detalhes e mudanças no ambiente afetam ARKit.

## Gestos e lente

Indicador: clique após mais de dois segundos. Pinça: arraste. Palma sobre janela: redimensionamento após estabilizar; profundidade quando disponível ou variação do tamanho aparente da mão. Palma em região livre por um segundo: reenquadrar a última janela quando saiu do enquadramento ou ficou de lado. Um gesto de palma dispara uma vez até a mão relaxar. Cliques e arrastes preservam a correção da revisão 25 e não exigem profundidade do dedo.

Seleção de ultra-angular real somente se estiver em ARWorldTrackingConfiguration.supportedVideoFormats. Indicação da lente efetiva e aviso quando 0,5× indisponível para ARKit/LiDAR. Disponibilidade precisa ser verificada no iPhone, sem alegar sucesso antes disso.

## Personagens e interação

RobotExpressive, Tomás Laulhé / Quaternius, modificações de Don McCurdy, CC0; Fox, PixelMannen e tomkranis, conversão de AsoboStudio/scurest, CC BY 4.0 para o conjunto. Fontes fixadas por commit, licenças e hashes incluídos em SpatialAuthoring/Sources. Blender 5.3.0 converte GLB em malhas, pesos, esqueletos e animações nativas. Conversão matemática comparada ao Blender em início, meio e fim de cada clipe: erro máximo menor que um micrômetro nos dois modelos.

Robô: 43 ossos, 3234 triângulos, Idle/Wave/Walking/Punch/Dance/Running. Raposa: 24 ossos, 576 triângulos, Survey/Walk/Run. Escalas 1,70 m e 0,45 m, origem no piso. Cada instância tem esqueleto próprio. Caminhada limitada ao apoio medido e sem atravessar obstáculos reconhecidos. Impacto visual experimental recortado na parede aprovada, sem representar fratura física real. A precisão depende da geometria medida; obstáculos não mapeados não são garantidos.

Mantido ARKit + SceneKit para preservar LiDAR, oclusão, persistência e controles nativos. Godot não estava instalado e não foi integrado; a troca de renderizador não é necessária para estas correções. Não há IA por quadro.

## Validação

Primeira execução (006209c, workflow 45290658373): 75 testes executados, com quatro falhas em dois testes de animação. O SceneKit recusou índices compactos intercalados e as poses renderizadas ficaram iguais. Esse pacote não foi instalado. Correção 96471cb converte índices em UInt16 e separa os vetores de pesos antes de construir SCNSkinner. A verificação nativa curta (workflow 45294055658) aceitou as 20 partes dos dois modelos. A nova execução completa e a revisão das poses continuam em andamento. Compilação arm64, pacote com extensão e hashes da correção passaram. Testes adicionados para backup/restauração sem perda, gestos de palma, esqueletos independentes, clips e renderização de poses distintas. Evidência visual deve ser revisada após a execução.

Validação física da revisão 26: pendente. Testar reinício completo, retorno de app, percurso quarto/sala/retorno, recuperação de mapa, palma para reenquadrar/redimensionar, lente efetiva, personagens e impacto. Nenhum resultado do simulador é registrado como aprovação física.

Ponte de desktop preservada da revisão 24/25: imagem JPEG, clique, rolagem, teclas e texto; áudio e múltiplos monitores não incluídos. Revisão 25 teve imagem real e gestos confirmados pelo usuário.

## Referências

- https://developer.apple.com/documentation/arkit/arsessionobserver/sessionshouldattemptrelocalization(_:)
- https://developer.apple.com/documentation/arkit/arconfiguration/supportedvideoformats
- https://developer.apple.com/documentation/arkit/arconfiguration/videoformat-swift.class/capturedevicetype
- https://github.com/mrdoob/three.js/tree/6d91309bfcf9c2779f32dd98b61fcc5415a74912/examples/models/gltf/RobotExpressive
- https://github.com/KhronosGroup/glTF-Sample-Assets/tree/e124e8d8d7330a5372bc2b4d00d39a4a9d7997ea/Models/Fox

Arquivos alterados: Core/SpatialGesture.swift, Core/SpatialPersistence.swift, Core/WallARCommand.swift, Views/SpatialDesktop.swift, Views/SpatialHands.swift, Views/SpatialPanel.swift, Views/SpatialWorld.swift, Views/WallARStudio.swift; novos Views/SpatialRig.swift e Views/WallImpact.swift; recursos animados e seus manifestos, testes, projeto Xcode, xtool.yml, versão, scripts de conversão/registro e guias desta entrega.


Atualização de validação: a segunda execução, workflow 45293101345, passou em 76 testes iOS sem falhas. A revisão 26 foi instalada e confirmada no iPhone. A inspeção visual encontrou translação na origem das animações do robô; o recurso foi corrigido e validado no workflow 45296407681, com apoio dos pés e renders nativos. A revisão 28 incorpora esse recurso, o menu recolhível e a correção da exibição dos ossos. Consulte RELATORIO_AR_REV28.md para o estado final.

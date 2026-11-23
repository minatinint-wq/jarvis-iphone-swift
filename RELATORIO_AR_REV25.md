# JARVIS XLV — AR persistente, gestos e área de trabalho

Revisão 25. Atualização de 23/11/2026.

## Diagnóstico inicial

O app existente usa SwiftUI, ARKit, SceneKit e Vision. A câmera do ARKit alimenta também o detector local de 21 pontos da mão. O painel tem botões projetados em um plano espacial. Os objetos eram descartados ao fechar a sessão. A troca de âncora alterava o identificador usado para o objeto. A malha LiDAR escrevia no mesmo buffer de profundidade dos cartões e podia esconder partes da interface.

Blender 5.3.0 foi executado no Windows para preparar os modelos. Godot não foi localizado no PATH, atalhos, registros de instalação ou pastas pesquisadas. Sua versão permanece sem confirmação. Após a autorização para escolher as ferramentas, mantive SceneKit como renderizador do iPhone. Migrar para Godot permanece fora desta implementação entregue. RoomPlan também permanece sem integração. Os nomes Quarto e Sala são atribuídos pelo usuário.

## Melhorias implementadas

O app mantém a mesma câmera, instrumentos, Spotify, controles, pintura medida e catálogo. Foram acrescentados persistência em disco, demos métricas, controles por profundidade e uma janela da área de trabalho do Windows no espaço AR. Ações semânticas usam WallARCommand e as coordenadas são calculadas localmente. Frames da mão e da reconstrução espacial permanecem no processamento local.

## Correções de renderização

Os cartões e a janela do PC usam camadas distintas da geometria de oclusão. Eles têm ordem de desenho explícita e não leem a profundidade da malha incompleta. Os objetos 3D continuam lendo essa profundidade. A segmentação de pessoas do ARKit continua habilitada nos dispositivos compatíveis. A colocação dos painéis verifica superfícies detectadas, mas a interface pode aparecer à frente de obstáculos não detectados. A oclusão visual da mão precisa de conferência física.

O painel inicial passa a ficar a 55 cm, com escala ajustada à área útil da tela. As texturas usam mipmaps e filtragem anisotrópica. A renderização mantém a meta de 60 FPS com redução térmica para 30 FPS. Essa meta depende de medição no aparelho.

## Gestos implementados

* Indicador sobre um botão por mais de dois segundos executa um clique. O clique por permanência usa o raio de apontamento e funciona quando a ponta está reconhecida por Vision, inclusive com profundidade ou polegar indisponíveis.
* Pinça confirmada durante pelo menos 120 ms captura o alvo e permite movê-lo. A abertura da pinça solta o objeto e cria sua nova âncora. Pinça não dispara clique.
* Palma aberta começa livre. Sobre o objeto selecionado, uma espera de 450 ms estabelece a referência de profundidade. Empurrar reduz e puxar aumenta. Há zona morta de 3,5 cm e limites de escala.
* Dois dedos em V continuam trocando as páginas do menu.
* Perda da mão, rastreamento ruim ou resultado do detector com mais de 450 ms cancela o gesto em andamento. A reaparição exige uma nova confirmação.

A profundidade usa uma região 3×3 com pelo menos seis amostras de alta confiança e variação menor que 4,5 cm. O teste físico deve confirmar se esses limiares são adequados para as suas mãos e a iluminação do ambiente.

## Personagens e objetos adicionados

Modelos preparados pelo Blender em metros, com origem no apoio inferior e sem geração por IA.

| Modelo | Medida de referência |
| --- | --- |
| Humanoide | 1,70 m de altura |
| Caixa | 0,30 m de lado |
| Cadeira | 0,90 m de altura |
| Mesa | 0,75 m de altura |
| Painel de demonstração | 0,60 m de largura |

Os arquivos editáveis .blend e os .glb ficam em SpatialAuthoring. O app usa as malhas locais JSP1 convertidas pelo mesmo script. Foram verificados os hashes dos recursos e as dimensões no Blender. O painel de demonstração é um objeto do catálogo. O painel principal e a tela do PC têm controles próprios.

## Persistência espacial implementada

Um arquivo JSON local reúne ARWorldMap arquivado com secure coding, identificador do imóvel, ambientes, objetos, painel e janela do PC. O conjunto é gravado atomicamente para evitar misturar um mapa com transformações de outra gravação. Os dados espaciais ficam na Application Support do app, com proteção de arquivos e exclusão do backup em nuvem.

Cada objeto registra ID estável, tipo, modelo, ambiente, âncora, matriz local com posição e rotação, escala, estado de persistência e data. Cada ambiente tem sua transformação de origem no referencial do mapa. A janela do PC salva sua âncora e escala, sem salvar as imagens recebidas.

Ao reabrir, o app fornece o mapa salvo ao ARKit, aguarda as âncoras correspondentes e rastreamento normal estável. A restauração por ID evita duplicação. Objetos aguardam ocultos quando a referência não foi recuperada. Não há reposicionamento pela câmera como alternativa de restauração.

Há salvamento manual e tentativa automática a cada 30 segundos quando há alterações e um mapa adequado. O fechamento rápido ou a suspensão do iOS podem impedir uma nova gravação. Use Salvar mapa e confira a confirmação antes do teste de reinicialização. O último arquivo válido é preservado em caso de falha.

Este é um mapa único do trajeto explorado, com ambientes nomeados manualmente. Não há reconhecimento automático de qualquer cômodo nem garantia de relocalização em todo imóvel. Alterações de móveis, pouca textura, reflexos e mudanças de iluminação podem prejudicar o ARKit.

## Área de trabalho do PC

No Espaço AR, toque no ícone do computador ou diga “abrir tela do computador”. Há também Tela do PC ao vivo em Cenários AR. Quando o centro da câmera encontra uma superfície vertical medida, ela orienta a distância inicial da janela. Isso não identifica automaticamente qual superfície é um monitor.

A ponte pareada captura o monitor principal em JPEG até 1280×800 e solicita atualizações com intervalo mínimo de 200 ms. O limite esperado é cinco atualizações por segundo, sujeito ao PC e à rede. A cena AR continua renderizando independentemente da chegada das imagens. A tela do Windows permanece funcionando normalmente.

A pinça segura a janela inteira. Puxar para cima muda a posição espacial da janela. Ao soltar, a janela fica ancorada. O indicador por dois segundos envia um clique ao Windows. O rodapé oferece entrada de texto, teclas básicas e rolagem. A digitação é enviada à janela que estiver em primeiro plano no Windows. Windows bloqueado, janelas elevadas e telas protegidas podem recusar captura ou entrada.

A transmissão usa a conexão já pareada do JARVIS e encerra a captura quando o AR pausa ou fecha. As imagens não são gravadas. Há validação de coordenadas, sequência do frame e limites de entrada. Essa primeira implementação transmite um monitor, sem áudio remoto, múltiplos monitores, botão direito ou arraste de arquivos dentro do Windows.

## Resultado do teste quarto → sala → quarto

Percurso entre cômodos ainda pendente. O usuário esclareceu que a falha observada ocorreu ao sair do aplicativo e voltar. A validação desse percurso permanece separada da retomada do app.

1. Entre em Espaço AR, abra Cenários 3D e escolha Quarto.
2. Mostre piso e detalhes ao redor. Posicione o humanoide e a caixa em pontos marcados fisicamente no chão.
3. Salve o mapa e confira a confirmação.
4. Caminhe até a sala com o AR aberto. Escolha Sala e coloque a cadeira e um painel.
5. Salve novamente. Retorne ao quarto e confira os pontos físicos, orientação e tamanho dos objetos.
6. Registre as diferenças em centímetros em relação às marcas do chão e aos cantos da parede.

## Resultado do teste após reiniciar

A revisão 24 falhou na retomada: objetos ficaram fora do lugar e flutuando. Na revisão 25, o usuário confirmou que sair do aplicativo e voltar recuperou o mesmo lugar físico. Em teste posterior de fechar e abrir, relatou recuperação indefinida. Reinício completo permanece sem aprovação e motivou a recuperação explícita da revisão 26. Os testes de arquivos não comprovam a posição física restaurada.

Após salvar, feche o app, reabra no ambiente original e mova a câmera lentamente para recuperar o mapa. Confira os mesmos pontos marcados, conte os objetos e compare posição, rotação e escala. Se a recuperação não ocorrer, registre esse resultado e o tempo de espera.

## Teste da tela do computador por pinça

Na revisão 24, a imagem real do PC apareceu, mas gestos ficaram travados. Na revisão 25, o usuário confirmou que indicador e pinça voltaram a funcionar. A profundidade deixou de bloquear clique e arraste. A captura real do Windows retornou JPEG válido de 1280×720. Os testes automatizados de entrada usam substitutos das funções do Windows para evitar ações involuntárias.

1. Deixe uma janela de teste aberta no PC e conecte o Jarvis do iPhone à ponte.
2. No Espaço AR, aponte para o monitor e abra Tela do PC.
3. Confira que mudanças no Windows aparecem na janela virtual.
4. Encoste a mão no plano virtual, feche a pinça sobre a imagem e puxe para cima.
5. Solte a pinça, afaste o iPhone e volte a olhar para a janela. Confira que permanece na posição de soltura e continua atualizando.
6. Aponte o indicador para um botão seguro por dois segundos e confirme a ação no Windows. Teste também um texto de teste e a rolagem.
7. Salve o mapa, reinicie e confira a posição da janela restaurada antes de retomar o controle.

## Desempenho

O diagnóstico local registra FPS da cena, memória residente, quantidade de objetos, estado térmico, bateria informada pelo iOS e duração de relocalização observada. Quando as âncoras retornam, registra diferenças de posição e orientação em relação às matrizes salvas. Essas diferenças numéricas não substituem a comparação com as marcas físicas.

Use Compartilhar diagnóstico em Cenários 3D para exportar o arquivo. Não foi medido consumo de bateria, FPS no iPhone, latência ponta a ponta ou tempo real de recuperação entre cômodos nesta etapa.

## Validação desta entrega

* Blender executado e dimensões dos cinco modelos verificadas.
* Hashes e referências de recursos verificados localmente.
* Três testes Python do desktop aprovados.
* Quarenta e sete testes Node da ponte aprovados.
* Captura real do monitor principal validada sem gravação da imagem. Quatro capturas tiveram média de 164 ms e aproximadamente 78 KB de JPEG. O atraso de rede até o iPhone não foi medido.
* Revisão 25: compilação arm64, empacotamento e 70 testes iOS aprovados no workflow 45285186399, commit 975b905. A imagem de referência do painel central foi examinada; não representa câmera física.
* Instalação 1.2.0 (25) confirmada pelo serviço da Apple. O usuário confirmou clique por indicador, arraste por pinça e retorno ao mesmo lugar físico ao sair e voltar do aplicativo. Em teste posterior de fechar e abrir, relatou mapeamento indefinido. Reinício completo e percurso entre cômodos permanecem sem aprovação.

## Arquivos e dependências

Novos arquivos principais no app incluem Core/SpatialPersistence.swift e Views/SpatialDesktop.swift. Foram alterados SpatialWorld.swift, SpatialHands.swift, SpatialGesture.swift, SpatialPanel.swift, WallARStudio.swift, WallARCommand.swift, RemoteAssistant.swift, PhoneCommandTests.swift, recursos e configurações de empacotamento.

Na ponte, server/desktop.py e server/desktop.cjs implementam captura e entrada. session.cjs e bridge.cjs fazem o encaminhamento pela sessão pareada. tests/test_desktop.py verifica o módulo. As cópias de recuperação dos arquivos anteriores ficam em D:/JARVIS/CACHE/ios-dev/backup-desktop-rev24.

APIs usadas incluem ARWorldMap, ARAnchor, NSKeyedArchiver, ARDepthData, Vision Hand Pose, SceneKit e funções Win32 de entrada. Pillow já estava disponível no Python da ponte. Nenhuma nova dependência paga foi adicionada. O script scripts/build-spatial-demo.py deve ser executado pelo Blender para regenerar os modelos.

Fontes oficiais consultadas

* [Salvar e restaurar dados do mundo em ARKit](https://developer.apple.com/documentation/arkit/saving-and-loading-world-data)
* [Qualidade do rastreamento e relocalização](https://developer.apple.com/documentation/arkit/managing-session-life-cycle-and-tracking-quality)
* [Plugins nativos para iOS no Godot](https://docs.godotengine.org/en/stable/tutorials/platform/ios/ios_plugin.html)

## Problemas restantes

A validação física da oclusão da mão, conforto visual, restauração entre cômodos e gestos permanece necessária. Godot e RoomPlan não foram integrados. Identificação de ambientes é manual. Recortes e materiais da pintura medida continuam com duração da sessão atual. A tela do PC usa o monitor principal e tem atualização limitada pela captura JPEG e pela ponte. Reconhecimento automático do monitor e suporte completo a todos os comandos de uma ferramenta de desktop remoto permanecem pendentes.

## Compilação e execução

O código Swift desta entrega está no commit 975b905. O workflow JARVIS iPhone via xtool compila arm64, verifica todos os recursos do IPA e executa os testes no simulador. Em um ambiente xtool configurado com SDK de iOS, execute `xtool dev build --ipa` na raiz do projeto. O arquivo assinado para este aparelho é preparado pelo fluxo pessoal de instalação existente.

A instalação do teste usa o script existente D:/JARVIS/CACHE/ios-dev/probe-review-usb.py e é confirmada consultando a versão instalada. A ponte do PC usa D:/JARVIS/PROJETO/apps/jarvis-remote/tools/start.ps1. Ela já foi reiniciada com esta atualização e confirmou conexão ao serviço remoto.


## Inventário dos arquivos alterados

A lista abaixo é relativa à raiz do projeto Swift. A cópia de trabalho está em D:/JARVIS/CACHE/ios-dev/build-src e a cópia organizada está em D:/JARVIS/PROJETO/outputs/08_IPHONE_SWIFT.

```text
JarvisPhone.xcodeproj/project.pbxproj
JarvisPhone/Core/SpatialGesture.swift
JarvisPhone/Core/SpatialPersistence.swift
JarvisPhone/Core/WallARCommand.swift
JarvisPhone/Resources/SPATIAL_ASSETS.json
JarvisPhone/Resources/Spatial_demo_box_0.mesh
JarvisPhone/Resources/Spatial_demo_chair_0.mesh
JarvisPhone/Resources/Spatial_demo_chair_1.mesh
JarvisPhone/Resources/Spatial_demo_chair_2.mesh
JarvisPhone/Resources/Spatial_demo_chair_3.mesh
JarvisPhone/Resources/Spatial_demo_chair_4.mesh
JarvisPhone/Resources/Spatial_demo_chair_5.mesh
JarvisPhone/Resources/Spatial_demo_human_0.mesh
JarvisPhone/Resources/Spatial_demo_human_1.mesh
JarvisPhone/Resources/Spatial_demo_human_10.mesh
JarvisPhone/Resources/Spatial_demo_human_11.mesh
JarvisPhone/Resources/Spatial_demo_human_12.mesh
JarvisPhone/Resources/Spatial_demo_human_2.mesh
JarvisPhone/Resources/Spatial_demo_human_3.mesh
JarvisPhone/Resources/Spatial_demo_human_4.mesh
JarvisPhone/Resources/Spatial_demo_human_5.mesh
JarvisPhone/Resources/Spatial_demo_human_6.mesh
JarvisPhone/Resources/Spatial_demo_human_7.mesh
JarvisPhone/Resources/Spatial_demo_human_8.mesh
JarvisPhone/Resources/Spatial_demo_human_9.mesh
JarvisPhone/Resources/Spatial_demo_panel_0.mesh
JarvisPhone/Resources/Spatial_demo_panel_1.mesh
JarvisPhone/Resources/Spatial_demo_panel_2.mesh
JarvisPhone/Resources/Spatial_demo_panel_3.mesh
JarvisPhone/Resources/Spatial_demo_table_0.mesh
JarvisPhone/Resources/Spatial_demo_table_1.mesh
JarvisPhone/Resources/Spatial_demo_table_2.mesh
JarvisPhone/Resources/Spatial_demo_table_3.mesh
JarvisPhone/Resources/Spatial_demo_table_4.mesh
JarvisPhone/Services/RemoteAssistant.swift
JarvisPhone/Views/SpatialDesktop.swift
JarvisPhone/Views/SpatialHands.swift
JarvisPhone/Views/SpatialPanel.swift
JarvisPhone/Views/SpatialWorld.swift
JarvisPhone/Views/WallARStudio.swift
JarvisPhoneTests/PhoneCommandTests.swift
SpatialAuthoring/demo_box.blend
SpatialAuthoring/demo_box.glb
SpatialAuthoring/demo_chair.blend
SpatialAuthoring/demo_chair.glb
SpatialAuthoring/demo_human.blend
SpatialAuthoring/demo_human.glb
SpatialAuthoring/demo_panel.blend
SpatialAuthoring/demo_panel.glb
SpatialAuthoring/demo_table.blend
SpatialAuthoring/demo_table.glb
SpatialAuthoring/dimensions.json
Support/Phone.plist
scripts/build-spatial-demo.py
scripts/test-phone-media.swift
xtool.yml
```

Arquivos da ponte em D:/JARVIS/PROJETO/apps/jarvis-remote

```text
server/desktop.py
server/desktop.cjs
server/session.cjs
server/bridge.cjs
tests/test_desktop.py
tests/desktop-session.test.cjs
```


## Correção após teste físico da revisão 24

A revisão 25 restaura o clique e a pinça por projeção do cursor sobre a janela. A profundidade deixa de bloquear essas ações. O arraste mantém a distância projetada e a orientação da janela durante a pinça. Palma para redimensionar continua dependendo de profundidade válida. Foram acrescentados testes de apontamento contínuo e uma chamada ao componente real da janela do PC, simulando clique, pinça e arraste sem profundidade da mão. O diagnóstico passa a registrar latência do detector, mão encontrada e profundidade encontrada. O arquivo salvo não é substituído enquanto alguma janela estiver sendo arrastada.


## Correção de relocalização após o segundo teste físico

Foi implementado sessionShouldAttemptRelocalization retornando true. Assim o ARKit continua tentando reencontrar o referencial conhecido após uma interrupção. A documentação oficial descreve que a ausência desse método permite uma tentativa curta seguida de reinício da sessão, que pode deixar âncoras antigas fora de sincronia com o mundo real.

Além disso, a exibição dos modelos passa a exigir nova confirmação da superfície de apoio após pausa, retomada ou perda de rastreamento. A conferência amostra cinco pontos da superfície, usa profundidade de alta confiança e exige duas observações concordantes. Posição, orientação e altura relativa do objeto continuam vindo dos dados salvos. A conferência não muda a posição para caber no local atual. Dados da revisão 24 recuperam o apoio a partir dos planos medidos do mapa salvo quando disponíveis.

Mostre o piso ou a mesa sob o objeto ao retornar. Superfícies brilhantes, ocultas ou sem profundidade confiável podem impedir essa confirmação. O objeto aguarda oculto. Essa correção precisa repetir o teste físico e não garante a posição horizontal em ambientes visualmente ambíguos. A comparação com marcas físicas continua obrigatória para aprovar o resultado.

[Documentação da recuperação do rastreamento](https://developer.apple.com/documentation/arkit/arsessionobserver/sessionshouldattemptrelocalization(_:))

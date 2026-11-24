# JARVIS AR — revisão 28

Esta entrega reúne a recuperação do mapa, os gestos de palma, personagens animados e os dois últimos ajustes solicitados: recolher o menu grande e manter visível o esqueleto da mão.

## Menu e detecção da mão

O X ao lado do seletor Medir e pintar / Cenários 3D recolhe o bloco completo. Um botão pequeno Ferramentas permite reabrir. A preferência fica salva; recolher não troca de módulo nem encerra a sessão ou os objetos.

Vision passa a receber os quadros também durante o mapeamento e sem painel ou módulo 3D ativo. O desenho dos ossos fica numa UIView transparente própria, acima da câmera e da orientação do ARKit. O indicador e os ossos não dependem da profundidade. As ações espaciais continuam bloqueadas enquanto rastreamento ou âncoras não estiverem recuperados. Não foi alterado o classificador dos dedos ou o tempo de clique/pinça.

## Recuperação, gestos e lente

Depois de 20 segundos sem recuperar rastreamento ou âncoras, há orientação, nova tentativa, escolha de mapa guardado e novo mapa com confirmação. O último mapa fica preservado. Um reset solicitado durante segundo plano é aplicado ao retornar. Mapas ilegíveis também têm saída de recuperação.

Indicador por mais de dois segundos clica; pinça segura move e soltar fixa. Palma sobre a janela, após estabilizar, aproxima para ampliar e afasta para reduzir. Palma fora das interfaces por um segundo reenquadra a última janela desenquadrada. Fechar a mão permite repetir. Redimensionamento usa profundidade quando confiável ou tamanho aparente da palma quando ausente.

O seletor tenta a ultra-angular real somente entre formatos oferecidos pelo ARKit. Se não houver 0,5× na sessão com LiDAR, informa a restrição e usa 1×. A disponibilidade efetiva precisa ser conferida no aparelho.

## Personagens

RobotExpressive (CC0) e Fox (CC BY 4.0 para o conjunto) têm esqueletos independentes e animações prontas, com fontes e atribuições incluídas. Robô: 43 ossos, 3234 triângulos, 1,70 m; raposa: 24 ossos, 576 triângulos, 45 cm. O robô acena, dança e caminha; a raposa observa, caminha e corre. A caminhada usa o apoio medido. O impacto é um efeito virtual experimental no recorte aprovado da parede, sem simulação de fratura estrutural.

A primeira verificação detectou índice ósseo incompatível; foi corrigido para UInt16 e vetores separados. A revisão visual seguinte identificou uma translação de aproximadamente 1,024 m nos clipes importados do robô. O conversor remove essa origem constante, preservando a movimentação do corpo. O teste nativo verifica apoio dos pés, dimensões e quatro poses renderizadas. Foram conferidas as imagens do robô em duas poses e da raposa correndo.

## Evidências e limites

- Código do núcleo 96471cb: compilação arm64, extensão e 76 testes iOS aprovados, workflow 45293101345.
- Recursos corrigidos f9f1b7a: 20 partes aceitas pelo SceneKit, apoio dos pés e quatro renders aprovados, workflow 45296407681.
- Revisão 28, código 4045e5a: compilação arm64 e pacote com extensão aprovados no workflow 45297351130. Alterações posteriores ao núcleo se limitam à apresentação do menu e da mão. O modo de compilação visual não repete a suíte completa do simulador; não se registra como se a tivesse repetido.
- Os hashes de todos os recursos AR e a presença da extensão são conferidos no pacote. O rosto personalizado do usuário é preservado pelo empacotamento pessoal.
- Instalação 1.2.0 (28) confirmada pelo serviço da Apple em 23/11/2026, após retorno de sucesso do instalador e consulta da versão. Validação física dos ossos, menu, gestos e mapa ainda depende do usuário.

Na revisão 25, o usuário confirmou clique/pinça e retorno ao mesmo lugar ao sair e voltar do app. Posteriormente relatou mapeamento indefinido ao fechar e abrir. Na revisão 26, relatou desaparecimento dos ossos. Esses resultados motivaram as correções; ainda não constituem aprovação física da 28. Percurso entre cômodos, 0,5× efetivo, desempenho e novos gestos continuam a exigir teste no iPhone.

O motor permanece ARKit + SceneKit com detecção local por Vision. Não foi integrado Godot nem RoomPlan. Blender 5.3.0 prepara as malhas e animações fora do aparelho. O funcionamento e as limitações anteriores estão detalhados em RELATORIO_AR_REV25.md e RELATORIO_AR_REV26.md.

Arquivos desta etapa: Views/WallARStudio.swift, Views/SpatialHands.swift, configuração de versão e workflow, recursos de animação e seus manifestos, scripts de conversão/verificação e os guias desta entrega. Nenhuma credencial é incluída nos relatórios.

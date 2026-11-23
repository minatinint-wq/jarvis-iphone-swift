# Revisão 19 — AR utilizável em retrato

Correções a validar no iPhone: painel orientado pela gravidade e câmera da tela, tamanho limitado pela projeção na tela, quatro cartões por página, controles de transporte do Spotify separados da lista. A malha de oclusão não participa da seleção. Arrastar o painel exige segurar sua barra superior; cartões continuam disponíveis por toque na tela.

O indicador pode aparecer mesmo com o punho fora da imagem. Uma pinça só produz ação quando indicador, polegar e escala da mão têm evidência suficiente. Falhas e demora no detector aparecem no diagnóstico; não são tratadas como ausência silenciosa da mão. Nenhum teste de simulador prova detecção física ou estabilidade em todas as iluminações.

## Objetos e cenários

20 modelos adicionais prontos, licenciados, locais, com partes e texturas preservadas. Catálogo por páginas; tamanho inicial de até 30 cm; toque para selecionar/interagir, arraste para mover, pinça e rotação com dois dedos. O giro de inspeção dos objetos é uma interação nativa, não uma animação esquelética importada. Créditos completos: SPATIAL_LICENSES.txt.

Seis cenários: bosque, bosque noturno, estúdio, garagem, sala interativa e jardim aquático. Na garagem, tocar inicia/para o deslocamento do carro dentro da base. Na sala, alterna a iluminação. No jardim aquático, pausa/retoma o movimento do peixe. Os cenários são composições de mesa/piso; não remodelam automaticamente o quarto inteiro.

Comandos: “abrir painel”, “abrir módulo cenários”, “cenário garagem”, “sala interativa”, “jardim aquático”. A navegação flexível por IA usa os cartões da página atual. Abra o catálogo para os objetos individuais.

Máximo de seis conjuntos e 350 mil triângulos carregados na cena. Áreas de apoio precisam estar mapeadas. Portas fechadas e superfícies coplanares ainda exigem exclusão manual na pintura. Extensões ópticas glTF avançadas são aproximadas pelo material PBR nativo, não reproduzidas integralmente.

## Validação necessária

Compilação arm64 + testes XCTest e capturas de renderização. Regressões: orientação em retrato, limite de projeção, pinça sem punho, ausência de polegar, malha invisível interceptando cliques, páginas dos cartões, abertura dos 20 modelos e ações dos três cenários novos. Após instalação: testar orientação, cursor no dedo, pinça e movimentação em ambiente real; não marcar como aprovado apenas porque compilou.

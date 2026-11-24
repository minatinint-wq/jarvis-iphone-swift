# JARVIS — revisão 32 — duas imagens completas no VR Box

Fonte do aplicativo: db89c250a2e75934c370fb3989f885fceae3948a.
Compilação xtool/arm64 e pacote com extensão: 45501256333, aprovado.
XCTest no simulador iOS: 45502057519 aprovado, 5 testes e zero falhas. Probe direto no Metal do macOS: 45504089931 aprovado. O probe usa o compositor extraído da mesma fonte; as árvores de runtime db89c25 e 7ece1c5 são idênticas. Instalação confirmada pelo iOS: JARVIS 1.2.0 build 32 / VERIFIED_JARVIS_BUILD=32. Aceitação física no VR Box pendente.

## Problema confirmado pelo usuário

Na revisão 31, com o iPhone na horizontal, os dois lados pareciam uma imagem contínua. O teste anterior verificava as dimensões das duas ARSCNView e imagens de uma cena sintética, mas não a câmera. Ele não validava o caminho que falhou no aparelho. A causa interna exata do comportamento do ARKit não foi reproduzida no simulador.

## Mudança

Foi removida a segunda ARSCNView. O novo compositor usa a captura da única ARSession existente e uma renderização da cena 3D. A câmera YCbCr é lida diretamente com CVMetalTextureCache. Dois viewports com recorte próprio amostram a mesma imagem completa e a mesma textura da cena. Uma faixa preta separa os olhos. A vista normal não renderiza escondida em paralelo; é mantida para sessão, coordenadas e entrada.

A orientação, a transformação de exibição do ARFrame e a projeção da câmera usam o tamanho de um olho. Os dois lados usam exatamente os mesmos dados. Cursor e ossos são apresentados nos dois olhos sem duplicar Vision. Sair do modo restaura a câmera e o fundo normais sem reiniciar o mapa. O compositor respeita o limite de FPS e participa da medição existente.

Não há leitura de pixels para CPU ou criação de UIImage por quadro no uso real. O readback abaixo existe somente no teste. Continua sendo vídeo monocular duplicado; não foram adicionadas disparidade binocular ou calibração óptica das lentes.

## Teste que faltava

O teste alimenta o compositor real com um pixel buffer YCbCr contendo quatro faixas de cores e renderiza um cubo 3D branco. Ele lê o resultado final da GPU e exige:

- Zero pixels divergentes entre as duas áreas dos olhos.
- Todas as quatro faixas completas em cada lado, com as cores esperadas.
- Cubo da cena composto sobre a câmera nos dois lados.
- Faixa central preta, sem continuação do vídeo.
- Os mesmos resultados com transformação de imagem invertida em 180 graus.

O teste salva as imagens efetivamente renderizadas, JARVIS-VRBOX-GPU e JARVIS-VRBOX-GPU-ROTATED. Elas não substituem a captura física do quarto nem o teste do suporte.

Também são executados os casos de compartilhamento da sessão e retorno ao viewport normal, comandos do visor, ícone/radial e deduplicação de quadros. A suíte de 83 casos da revisão 31 permanece registrada no relatório anterior; não é apresentada como uma nova execução integral da revisão 32.

Referências: [câmera ARKit e Metal](https://developer.apple.com/documentation/arkit/displaying-an-ar-experience-with-metal) e [renderização SceneKit em command buffer Metal](https://developer.apple.com/documentation/scenekit/scnrenderer/render(attime:viewport:commandbuffer:passdescriptor:)).

## Resultado observado

As imagens geradas pelo iOS e pelo probe direto da GPU foram abertas e inspecionadas. Cada olho contém as quatro faixas completas e o cubo branco; a faixa central é preta. A comparação encontrou zero pixels divergentes nas duas orientações. A imagem do ícone recolhido e do radial aberto também foi inspecionada. São fixtures de câmera YCbCr, não imagens do quarto real.

O pacote original passou no validador do IPA. A versão pessoal preserva 21 recursos visuais anteriores e confere 9 mapas e 362 arquivos espaciais por hash. Instalação só é liberada pelo manifesto com hash do pacote e provas de validação.

A preparação do instalador demorou no acesso ao arquivo pelo compartilhamento Windows/WSL. Uma cópia local em /tmp foi validada com o mesmo SHA-256; antes de interromper qualquer processo, a preparação original terminou. O instalador original concluiu e confirmou a revisão 32. Nenhum processo de instalação foi encerrado.

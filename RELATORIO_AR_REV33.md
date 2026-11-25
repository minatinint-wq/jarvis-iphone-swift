# Revisão 33 — resultado no aparelho

Fonte f5def1de1da314dde587b6562a4ede4e2f217338. Pacote arm64: execução 45507522471 aprovada. XCTest direcionado: 45507577297, oito testes aprovados. Probe Metal: 45507528230 aprovado. A instalação foi verificada pelo iOS como 1.2.0 (33), VERIFIED_JARVIS_BUILD=33.

O usuário confirmou que a câmera voltou a rodar. Porém, a imagem enviada depois mostra uma única câmera contínua, embora existam dois botões Sair VR. Portanto, o modo óculos não foi aceito como corrigido. As imagens sintéticas do compositor não comprovavam a apresentação final da câmera no aparelho. A causa exata da apresentação contínua não foi isolada.

A revisão inclui a correção da falsa recuperação causada apenas por quadros lentos, renderização fora da thread principal, escala por duas pinças e zoom de toque. O resultado físico desses gestos nesta revisão ainda depende de teste do usuário.

O Holo Comandos foi localizado em D:/iPhone-Apps/HoloComandos-2026-11-20. Sua implementação usa duas UIView recortadas, cada uma com AVSampleBufferDisplayLayer e hologramas por cima. Essa estrutura é a referência da revisão 34, mantendo a ARSession existente do Jarvis.

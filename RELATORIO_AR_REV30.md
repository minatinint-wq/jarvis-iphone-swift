# JARVIS AR — revisão 30

Retorno físico em 24/11/2026: o usuário relatou afastamento e retorno do painel, com e sem mãos, e necessidade frequente de Novo mapa. A revisão 30 não foi considerada aprovada para estabilidade. Investigação e alterações seguintes registradas na revisão 31.

Código do aplicativo: 4894508a9d840f5732ea7167379a41d8789d7ef0. Pacote 1.2.0 (30), compilação 45304006676 aprovada. A revisão 29 voltou a apresentar lentidão após começar funcionando, conforme teste do usuário; não foi aprovada no uso sustentado.

## Ambiente fixo por padrão

A configuração inicial desliga reconstrução de malha, profundidade, segmentação de pessoas, detecção contínua de planos, iluminação e reflexos automáticos. A câmera, o rastreamento básico do ARKit e a detecção independente da mão continuam necessários e ativos.

O botão Escanear 8 s habilita temporariamente a leitura de planos e, se disponível, profundidade. Parar leitura encerra antes. Malha e segmentação de pessoas permanecem desligadas mesmo nesse intervalo. A operação não redefine o mapa nem os objetos; é interrompida ao sair da sessão. A atualização periódica e gravação automática contínua do mapa foram retiradas do caminho de cada quadro. Salvar manualmente e guardar ao entrar em segundo plano permanecem disponíveis.

A oclusão dinâmica por pessoas e malha deixa de funcionar nesse perfil. O zoom da pinça usa o tamanho aparente da palma quando não há profundidade; é uma estimativa, não uma medida métrica. Âncoras salvas só são reapresentadas após a localização normal do ARKit e recuperação das referências.

## Verificação

O workflow 45304006676 compilou o app arm64 e sua extensão, verificou recursos e executou os testes direcionados de mãos e gestos, incluindo imagens reais de entrada do Apple Vision. A suíte integral do simulador não foi repetida nesta revisão.

O teste nativo 45304014210 passou usando a API real do ARKit no simulador: configuração padrão sem planos, malha, profundidade, pessoas ou ambiente; leitura manual com planos e profundidade condicional, duração configurada de oito segundos. Esse teste verifica a configuração, não mede FPS do iPhone nem comprova o temporizador em uso físico.

O pacote pessoal preserva 21 recursos visuais, nove mapas de materiais e 362 arquivos espaciais. SHA256: 6956ccc05c46291f5506c63500a08a6926e39dfc40dcc49f94163b903b0f161c.

Instalação confirmada pelo serviço da Apple: VERIFIED_JARVIS_BUILD=30 (1.2.0 build 30), em 23/11/2026. Validação física sustentada: pendente. Testar por pelo menos dois minutos a mão, clique por indicador e pinça em Ambiente fixo; depois testar uma leitura manual e a retomada do mapa. Consulte COMO_TESTAR_AR_REV30.txt.

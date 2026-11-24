Ponte do computador — suporte ao teclado projetado e à rolagem

Aplicado no PC: D:/JARVIS/PROJETO/apps/jarvis-remote/server/desktop.py.
O helper é iniciado pelo servidor apenas durante uma sessão Desktop pareada. Ao fechar e reabrir essa sessão, a nova versão é carregada; não é necessário reiniciar a voz do Jarvis.

A detecção automática de campo usa pywinauto/comtypes, já presentes neste PC. Lê somente tipo, habilitação, foco e se o campo permite edição. Não lê nome, valor ou senha. Se a acessibilidade do programa não expuser o campo, o teclado manual continua disponível por três dedos ou pelo botão projetado.

Validação: 7 testes Python e teste de pareamento/deduplicação do protocolo Node. Nenhuma tecla foi enviada a aplicativos reais durante os testes automatizados. O arquivo desktop.patch registra a mudança e o cache local guarda a versão anterior para reversão.

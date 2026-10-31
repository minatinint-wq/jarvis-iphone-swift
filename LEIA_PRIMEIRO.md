# JARVIS XLV — iPhone em Swift

Projeto nativo SwiftUI para iPhone com iOS 17 ou posterior. Possui painel com 19 ações, 19 ações individuais no app Atalhos e duas ações parametrizadas adicionais. Não há frases de Siri, AppShortcutsProvider, assistente de voz ou conexão ativa com o backend Jarvis.

## Como instalar no iPhone

Você não envia o ZIP para o portal Apple Developer. Abra o projeto no Xcode em um Mac, compile e instale:

1. Extraia o ZIP e abra **JarvisPhone.xcodeproj** na versão estável atual do Xcode, compatível com seu iPhone. O código tem alvo mínimo iOS 17.
2. Em **Xcode → Settings → Accounts**, adicione sua conta Apple Developer.
3. Selecione o projeto, target **JarvisPhone → Signing & Capabilities**. Escolha sua **Team**, mantenha **Automatically manage signing** ligado e troque `com.jarvisxlv.iphone` por um Bundle Identifier exclusivo da sua conta, se necessário.
4. Conecte o iPhone ao Mac, aceite confiar no computador e ative **Modo de Desenvolvedor** no iPhone, se solicitado. Selecione o iPhone como destino e clique **Run (▶)**.
5. Abra o JARVIS XLV instalado. As permissões aparecem somente ao usar a função correspondente.
6. Para os controles do sistema, transfira **Shortcuts/JARVIS Sistema.shortcut** para seu iCloud Drive. No iPhone, abra **Arquivos → iCloud Drive → JARVIS Sistema.shortcut → Adicionar Atalho**. Preserve o nome **JARVIS Sistema**. Também é possível compartilhar esse arquivo pela tela Configuração dentro do app.
7. No app Atalhos, procure **JARVIS XLV** em **Adicionar Ação**. As 19 ações individuais aparecem pelo nome: **Ligar lanterna**, **Abrir WhatsApp**, **Criar lembrete**, etc. Também há **Executar ação no iPhone**, com ação e porcentagem opcionais, e **Ajustar brilho do iPhone**, com porcentagem. Não é preciso configurar a Siri.

Só a confirmação de instalação do atalho auxiliar é manual; as ações já estão montadas. Um ZIP de código Swift não é um aplicativo instalável diretamente pelo iPhone.

## Para disponibilizar pelo TestFlight

1. Crie o registro do app em App Store Connect, usando o mesmo Bundle ID definido no Xcode.
2. No Xcode, selecione um destino iOS de distribuição e use **Product → Archive**.
3. No Organizer, selecione **Distribute App → App Store Connect → Upload** e siga a validação de assinatura.
4. Após o processamento, abra a aba **TestFlight** do app em App Store Connect e adicione o teste interno. Testes externos podem exigir revisão da Apple.

A assinatura Apple Developer cobre os apps da sua conta. Não há arquivo IPA compilado neste pacote: ele precisa ser gerado no Xcode/macOS com sua Team. Nenhuma credencial Apple foi incluída.

## Teste pelo Windows com o iPhone físico

O workflow externo também gera **JARVIS-iPhone-SEM-ASSINATURA.ipa**, com binário arm64 para aparelho real. Ele ainda não instala diretamente: falta assinar e provisionar para sua conta/dispositivo.

Uma opção para assinar e instalar pelo Windows é o **Sideloadly**, que aceita contas Apple gratuitas e contas Apple Developer pagas: https://sideloadly.io/ . Confira os pré-requisitos de drivers Apple no site oficial. Conecte o iPhone por USB, aceite confiar no PC, carregue o IPA e faça a autenticação no aplicativo local. Preserve o Bundle ID quando possível. Pode ser necessário ativar Modo de Desenvolvedor no iPhone. Câmera, lanterna e disponibilidade das ações em Atalhos precisam ser validadas no aparelho após a instalação.

O IPA sem assinatura também não pode ser enviado diretamente ao TestFlight; para isso use o fluxo de distribuição assinado do Xcode ou um pipeline configurado com os certificados e perfis da sua conta. Nenhuma credencial deve ser enviada por este chat.

## O que cada ação faz

| Ação | Execução |
|---|---|
| Lanterna ligar/desligar | AVCaptureDevice no iPhone; indisponível no simulador sem câmera/flash. |
| Volume | Barra nativa MPVolumeView. Com porcentagem pelo App Intent, usa JARVIS Sistema. |
| Brilho | UIScreen; aceita 0–100 com validação. |
| Bateria | UIDevice; retorna erro quando o simulador não disponibiliza leitura. |
| Reunião | Atalho: ativa Não Perturbe e coloca mídia em 0%. Não altera o volume do toque. |
| Encerrar reunião | Atalho: desativa Não Perturbe e coloca mídia em 50%. Não restaura um volume anterior. |
| Economizar | Atalho: ativa Modo Pouca Energia e brilho em 25%. |
| Pausar/continuar/próxima | Atalho: envia controles ao reprodutor de mídia do iPhone. O comportamento depende do app e da fila ativa. |
| WhatsApp/Instagram | Abre o app instalado. Não lê nem envia mensagens. |
| Câmera/foto | Captura manual com prévia; salva no app Fotos após a permissão. |
| Localização | Localização durante o uso e abertura no Mapas; consulta expira em 30 segundos. |
| Lembrete | Editor e gravação real no app Lembretes, com data e alarme opcionais. |
| Anotar | Editor de notas locais no JARVIS; oferece compartilhar, inclusive para Notas. Não escreve silenciosamente no Apple Notas. |
| Bloquear tela | Atalho nativo do sistema. |

Abrir o app Atalhos não comprova que o comando terminou. O painel informa **pedido encaminhado**, e o resultado aparece no Atalhos. Não há uso de APIs privadas ou simulação de sucesso. Algumas operações exigem desbloqueio ou permissão. Não há execução remota permanente em segundo plano.

## Preparação para a próxima integração

Os controles já têm IDs estáveis. Links aceitos pelo app instalado:

```text
jarvisiphone://command?action=lanterna_ligar
jarvisiphone://command?action=brilho&value=40
jarvisiphone://command?action=reuniao
```

Esses links precisam ser abertos no iPhone. Nenhum servidor foi iniciado ou conectado ao Jarvis. A ponte futura deverá respeitar autenticação, confirmação das ações e as restrições de segundo plano do iOS.

## Validação

- Projeto e plists conferidos no Windows; código verificado por parser Swift.
- Atalho auxiliar compilado por Cherri, com normalização do descritor nativo de Não Perturbe, e assinado via HubSign/Apple; o resultado usa envelope AEA1. O serviço de assinatura recebeu apenas a definição genérica das ações, sem credenciais ou dados pessoais.
- XCTest de roteamento e validação de comandos incluído. Execute **Product → Test** no Xcode ou `scripts/verificar-mac.command`.
- Compilação com SDK iOS, testes XCTest e teste físico ainda precisam acontecer no Mac/iPhone. Não foram executados no Windows.

## Referências

- Apple: https://developer.apple.com/documentation/appintents
- Apple: https://developer.apple.com/documentation/mediaplayer/mpvolumeview
- Apple: https://developer.apple.com/documentation/eventkit/ekeventstore/requestfullaccesstoreminders(completion:)
- Apple: https://support.apple.com/guide/shortcuts/run-a-shortcut-from-a-url-apd624386f42/ios
- Cherri 2.3.0: https://github.com/electrikmilk/cherri/tree/v2.3.0
- Assinatura Cherri/HubSign: https://cherrilang.org/compiler/signing.html

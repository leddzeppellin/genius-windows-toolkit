# Internet Monitor para Windows

Pacote local para medir e acompanhar download, upload, ping, jitter e perda de
pacotes usando o Speedtest CLI da Ookla.

## Requisitos

- Windows 10 ou 11.
- Windows PowerShell 5.1 ou superior.
- WinGet disponível (normalmente já vem com o Windows 10/11 atualizado).
- Uma conta com permissão de administrador somente durante a instalação.

O monitor funciona depois como `SYSTEM`; sua conta do Windows não precisa ter
senha.

## Instalação rápida

1. Extraia o arquivo ZIP para uma pasta.
2. Clique com o botão direito em `Instalar.cmd`.
3. Escolha **Executar como administrador** e confirme a janela do Windows.
4. Aguarde a mensagem de conclusão. O primeiro teste pode levar alguns minutos.
5. O dashboard local será aberto no navegador.

Por padrão, a medição ocorre a cada 60 minutos. Cada Speedtest transfere uma
quantidade relevante de dados.

## Uso

- Abra o painel pelo atalho **Internet Monitor** criado na Área de Trabalho.
- Use os botões 24h, 7 dias, 30 dias ou Tudo para mudar o período.
- Use **Abrir CSV** para consultar ou importar o histórico completo.
- O painel recarrega os dados automaticamente a cada minuto.
- O histórico fica em `C:\InternetMonitor\data\historico-internet.csv`.
- Os erros ficam em `C:\InternetMonitor\logs\coleta-erros.log`.

A tarefa aparece na raiz da Biblioteca do Agendador:

- `InternetMonitor - Coleta`

## Alterar a frequência

Abra o PowerShell como administrador na pasta extraída e execute, por exemplo:

```powershell
.\Install-InternetMonitor.ps1 -IntervalMinutes 120
```

Isso atualiza a instalação preservando o histórico. O intervalo aceito é de 15
a 1440 minutos. Recomenda-se 60 ou 120 minutos. O aviso de dados desatualizados
é ajustado automaticamente ao intervalo, exceto se `staleAfterMinutes` tiver
sido personalizado no arquivo de configuração.

## Limites do painel

Edite `C:\InternetMonitor\config.json` para ajustar os limites:

```json
{
  "downloadMinMbps": 500,
  "uploadMinMbps": 500,
  "pingMaxMs": 50,
  "jitterMaxMs": 20,
  "packetLossMaxPct": 1
}
```

Salve e abra novamente o painel pelo atalho **Internet Monitor**. O atalho
sincroniza a configuração antes de abrir o dashboard. Esses valores servem para
destaque visual; não alteram a medição.

## Teste manual

Abra o PowerShell como administrador e execute:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\InternetMonitor\Collect-Internet.ps1"
```

Depois atualize o dashboard. Uma nova linha deverá aparecer.

## Diagnóstico rápido

- Painel não abre: execute o atalho da Área de Trabalho novamente.
- Limites não mudaram: feche a aba e abra o painel novamente pelo atalho.
- Sem medições novas: confirme no Agendador se a tarefa de coleta está habilitada.
- Status `Erro` no painel: consulte `C:\InternetMonitor\logs\coleta-erros.log`.
- Resultado baixo isolado: outro equipamento, Wi-Fi, VPN ou backup pode ter usado
  a conexão durante o teste. Compare vários resultados.
- Perda em um teste isolado pode ser transitória; investigue quando for recorrente.

## Desinstalação

Clique com o botão direito em `Desinstalar.cmd` e escolha **Executar como
administrador**.

Por segurança, o histórico é preservado em `C:\InternetMonitor\data`. Para
removê-lo também:

```powershell
.\Uninstall-InternetMonitor.ps1 -RemoveHistory
```

## Privacidade

O dashboard é um arquivo local e não abre nenhuma porta de rede. O CSV inclui o
nome do provedor, o servidor usado e a URL do resultado, mas não armazena o IP
público.

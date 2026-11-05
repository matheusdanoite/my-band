# Inventário de dados da Mi Band 10

## Escopo

Este inventário separa quatro situações:

1. observado diretamente no log BLE fornecido;
2. suportado pelo protocolo/código, mas não observado como valor no log;
3. calculado ou transformado pelo aplicativo;
4. não comprovado.

Fonte principal do log:

`/Users/matheusdanoite/.copilot/workspaces/3c9dbaa5-9f79-4242-a95f-d3aeb64f1c22/attachments/efbf83bc-61e5-4a70-84ba-f63faf9ac767-my-band-log-2026-11-05-1209.txt`

O log comprova comunicação BLE autenticada com uma `Xiaomi Smart Band 10 3567`; não comprova coleta ou upload para a nuvem da Xiaomi.

## Dados observados diretamente no log

| Dado | Evidência |
|---|---|
| Identificação e conexão da pulseira | Cabeçalho do log, linhas 4–6 |
| Bateria | Leituras `via GATT 2A19` e via protocolo, por exemplo linhas 586–590 e 1894–1901 |
| Arquivo de sono | `sleep-details v5`, linhas 600–604 |
| Intervalo de sono e fases | Sessão e 76 fases, linhas 325–326 |
| Frequência cardíaca no sono | 1.875 amostras no arquivo de sono, linha 325 |
| Intervalos RR batimento-a-batimento | 177 blocos e 107.239 intervalos, linha 327 |
| Reclassificação de estágios | 13 reclassificações, linha 327 |
| Arquivos de atividade diária | `daily-details v4` e `daily-summary v5`, linhas 191–194 e 600–604 |
| Calendário e lembretes enviados à pulseira | Sincronização registrada nas linhas 91–97 |
| Clima e previsão enviados à pulseira | Registros `Weather pushed`, por exemplo linhas 37–51 |

O arquivo de sono analisado registra explicitamente **zero SpO₂**:

`Sleep file ... 1 session(s), 76 phase(s), 1875 HR, 0 SpO₂ (no SpO₂ section in the header)` (linha 325).

## Dados suportados pelo protocolo/código, mas não observados como valores neste log

O parser de detalhes diários reconhece passos, calorias, distância, frequência cardíaca, SpO₂ e estresse:

- `My Band/BLE/PacketParser/DailyActivityParser.swift:1-14,92-146`
- Gadgetbridge, `DailyDetailsParser.java`:  
  <https://codeberg.org/Freeyourgadget/Gadgetbridge/src/branch/master/app/src/main/java/nodomain/gadgetbridge/service/devices/xiaomi/activity/impl/DailyDetailsParser.java>

O parser de resumo diário também define passos, calorias, frequência cardíaca, estresse, SpO₂ e horas em pé:

- `My Band/BLE/PacketParser/DailySummaryParser.swift:1-84`
- Gadgetbridge, `DailySummaryParser.java`:  
  <https://codeberg.org/Freeyourgadget/Gadgetbridge/src/branch/master/app/src/main/java/nodomain/gadgetbridge/service/devices/xiaomi/activity/impl/DailySummaryParser.java>

O protocolo/código suporta, mas o log não mostra valores decodificados inequívocos de:

- passos;
- calorias;
- distância;
- frequência cardíaca diária;
- SpO₂ diário;
- estresse;
- horas em pé;
- carga de treino e vitalidade;
- medições manuais de FC, SpO₂, estresse e temperatura;
- resumo e detalhes de treino;
- GPS de treino.

Os registros manuais reconhecidos pelo parser são:

- `My Band/BLE/PacketParser/ManualSamplesParser.swift:1-68`
- Gadgetbridge, `ManualSamplesParser.java`:  
  <https://codeberg.org/Freeyourgadget/Gadgetbridge/src/branch/master/app/src/main/java/nodomain/gadgetbridge/service/devices/xiaomi/activity/impl/ManualSamplesParser.java>

O parser de sono reconhece seções de fases, HR, SpO₂, ronco, RR e frequência respiratória, mas a presença desses campos varia por arquivo e versão:

- `My Band/BLE/PacketParser/SleepPacketParser.swift:1-35,90-142`
- Gadgetbridge, `SleepDetailsParser.java`:  
  <https://codeberg.org/Freeyourgadget/Gadgetbridge/src/branch/master/app/src/main/java/nodomain/gadgetbridge/service/devices/xiaomi/activity/impl/SleepDetailsParser.java>

Assim, não é correto afirmar que ronco, frequência respiratória ou SpO₂ estavam presentes no arquivo de sono deste log.

## Métricas derivadas pelo aplicativo

Os intervalos RR são dados recebidos da pulseira. HRV/SDNN é calculado no telefone:

- log: `177 beat-to-beat block(s), 107239 interval(s)` (linha 327);
- log: `HRV: 1748 minute value(s) (median SDNN 53 ms)` (linhas 51 e 358).

Também são derivados pelo aplicativo:

- consolidação e sanitização das fases do sono (`SleepPacketParser.swift:286-298`);
- MET/esforço físico (`Health/HealthKitManager.swift:224-247`);
- reconciliação de passos, distância e calorias com o iPhone (`Health/HealthKitManager.swift:250-325`);
- esforço do treino (`Health/HealthKitManager.swift:523-548`);
- comprimento da passada (`Health/HealthKitManager.swift:449-456`);
- recuperação da frequência cardíaca (`Health/HealthKitManager.swift:718-755`).

Essas métricas não devem ser apresentadas como sensores adicionais da pulseira.

## Captura bruta de movimento

O repositório contém um caminho experimental para solicitar e decodificar lotes brutos de acelerômetro e giroscópio:

- `My Band/BLE/RawSensorProtocol.swift:1-30` define amostras com timestamp e eixos `x/y/z`;
- `My Band/BLE/RawSensorProtocol.swift:31-78` constrói comandos de início, parada e ACK;
- `My Band/BLE/RawSensorCaptureService.swift:1-145` grava CSV em `Application Support/RawSensorCaptures` e limita a captura padrão a 60 segundos;
- `My Band/BLE/BandManager.swift:839-856` reconhece o treino sintético `sport=810` e encaminha os lotes;
- `My BandTests/RawSensorProtocolTests.swift:1-45` valida a decodificação de acelerômetro e giroscópio.

O log fornecido **não** contém:

- amostras XYZ de acelerômetro;
- amostras XYZ de giroscópio;
- início ou parada de captura bruta;
- ACKs de lotes brutos;
- confirmação de taxa de amostragem ou unidade dos eixos em hardware real.

Conclusão: existe suporte protocolar no código para investigar a captura em outro projeto, mas a captura efetiva não foi demonstrada neste log. Não é possível concluir que o fluxo seja contínuo, que funcione durante o uso normal ou que seja aceito por todos os firmwares.

## Não comprovado

Não há evidência suficiente, no log e nas fontes analisadas, para afirmar que a Mi Band 10:

- mede pressão arterial;
- mede glicose;
- fornece composição corporal;
- envia continuamente acelerômetro ou giroscópio durante o uso normal;
- incluiu SpO₂, ronco ou frequência respiratória no arquivo de sono analisado;
- enviou à nuvem da Xiaomi os dados observados.

## Conclusão

O log comprova sono, fases, frequência cardíaca, intervalos RR, bateria, arquivos de atividade e dados enviados à pulseira. O app calcula HRV/SDNN a partir dos intervalos RR. O protocolo/código suporta outras famílias de dados, mas elas não devem ser tratadas como observadas nesta sessão sem um log que mostre os valores decodificados.

Para um projeto de sensores de movimento, o próximo experimento correto é executar explicitamente o modo `sport=810`, registrar o log completo e verificar se aparecem lotes `rawSensorBatch` com timestamp e eixos `x/y/z`. Até essa validação, acelerômetro e giroscópio devem ser classificados como **possibilidade experimental**, não como capacidade comprovada em operação.

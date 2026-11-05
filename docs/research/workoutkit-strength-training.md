# WorkoutKit e musculação no Fitness do iOS 27

Data da análise: 2026-11-05

## Conclusão

É possível adicionar uma sessão de musculação ao ecossistema Fitness/HealthKit como
um `HKWorkout` usando `HKWorkoutActivityType.traditionalStrengthTraining` ou
`HKWorkoutActivityType.functionalStrengthTraining`. Um workout salvo no HealthKit
aparece como dado de treino do usuário e, no iOS, contribui automaticamente para os
anéis Exercício e Movimento quando há energia ativa associada.

Isso é diferente de usar o WorkoutKit para criar um treino planejado. A documentação
pública do WorkoutKit descreve sincronização de composições para o app Workout no
Apple Watch, em uma área dedicada com a identidade do app. Ela não documenta uma API
para inserir diretamente um treino de musculação na lista nativa do app Fitness do
iPhone, nem para criar uma sessão que o usuário possa iniciar como se fosse uma
modalidade nativa do Workout sem o app Workout/Apple Watch participar.

Portanto:

- **Registrar uma musculação concluída no Fitness/HealthKit:** suportado.
- **Planejar uma musculação e enviá-la ao Workout do Apple Watch:** potencialmente
  suportado como `CustomWorkout`, desde que o conteúdo seja representável como uma
  composição de etapas, metas e alertas.
- **Criar uma nova modalidade ou um exercício individual nativo no catálogo do
  Fitness:** não há API pública documentada para isso.
- **Escrever diretamente na interface ou banco privado do Fitness:** não suportado e
  não deve ser tentado.

Não há, na documentação pública consultada, uma mudança específica do iOS 27 que
altere esses limites. A conclusão se baseia nas APIs públicas atualmente
documentadas; recursos futuros não documentados não podem ser tratados como
disponíveis.

## O que o WorkoutKit faz

O framework WorkoutKit fornece modelos para criar, visualizar e sincronizar
composições de treino:

- `CustomWorkout`: treino intervalado estruturado com etapas, metas e alertas;
- `SingleGoalWorkout`: uma única meta, como distância, energia ou tempo;
- `PacerWorkout`: meta de distância e tempo;
- `SwimBikeRunWorkout`: composição para natação, ciclismo e corrida.

Depois de criar uma composição, o app a envolve em um `WorkoutPlan`. Esse plano pode
ser aberto no app Workout do Apple Watch com `openInWorkoutApp()` ou agendado por
`WorkoutScheduler`, após autorização do usuário. A documentação diz que as
composições agendadas aparecem em uma área dedicada do app Workout e incluem o ícone
e o nome do app.

O ponto importante é que esses objetos representam **composições planejadas**, não
uma operação genérica de escrita no histórico do app Fitness. A página do framework
não lista um tipo específico de musculação nem uma API para criar exercícios
personalizados no catálogo do Fitness.

Fonte primária:

- [WorkoutKit](https://developer.apple.com/documentation/workoutkit)
- [WorkoutPlan](https://developer.apple.com/documentation/workoutkit/workoutplan)
- [Customizing workouts with WorkoutKit](https://developer.apple.com/documentation/workoutkit/customizing-workouts-with-workoutkit)

## Como registrar musculação no HealthKit/Fitness

`HKWorkout` exige um `HKWorkoutActivityType`, e a enumeração oficial inclui:

- `traditionalStrengthTraining`: treino de força principalmente com máquinas ou
  pesos livres;
- `functionalStrengthTraining`: treino de força principalmente com pesos livres e
  peso corporal.

Para musculação de academia, `traditionalStrengthTraining` é a correspondência mais
precisa. Para circuitos funcionais, calistenia ou exercícios com foco funcional,
`functionalStrengthTraining` é mais adequado.

O app pode construir o workout com `HKWorkoutBuilder`, adicionar amostras de
frequência cardíaca e energia ativa, finalizar com `finishWorkout`, e salvar os
detalhes associados ao workout. A documentação do `HKWorkoutBuilder` descreve
explicitamente esse fluxo incremental e a criação/salvamento do `HKWorkout` ao
finalizar.

No iOS, a documentação de `HKWorkout` afirma que workouts contribuem
automaticamente para os anéis Movimento e Exercício. O anel Movimento usa amostras
de energia ativa associadas; o anel Exercício usa a duração total do workout. O
HealthKit também pode contabilizar o anel Em Pé para horas de relógio sobrepostas,
conforme as regras do sistema.

Fontes primárias:

- [HKWorkoutActivityType](https://developer.apple.com/documentation/healthkit/hkworkoutactivitytype)
- [HKWorkout](https://developer.apple.com/documentation/healthkit/hkworkout)
- [HKWorkoutBuilder](https://developer.apple.com/documentation/healthkit/hkworkoutbuilder)
- [Adding samples to a workout](https://developer.apple.com/documentation/healthkit/adding-samples-to-a-workout)
- [Workouts and activity rings](https://developer.apple.com/documentation/healthkit/workouts-and-activity-rings)

## Aplicação ao My Band

O repositório já contém o caminho correto para esse caso:

- `My Band/Health/HealthKitManager.swift` mapeia `WorkoutKind.strengthTraining`
  para `HKWorkoutActivityType.traditionalStrengthTraining`;
- o parser reconhece o preset de força da Mi Band;
- o workout é construído com `HKWorkoutBuilder`;
- a série de frequência cardíaca é associada ao workout;
- o projeto já trata energia, metadados, rota e esforço quando esses dados estão
  disponíveis.

Assim, não é necessário usar WorkoutKit para fazer o treino de musculação
sincronizado pela Mi Band aparecer no Fitness. O caminho adequado é continuar
registrando um `HKWorkout` no HealthKit. WorkoutKit só seria necessário caso o
produto também queira criar um **plano de treino** que o usuário inicia ou agenda no
Apple Watch.

## Limitações relevantes

1. **Exercícios individuais, séries, repetições e carga:** as APIs públicas
   consultadas não oferecem um modelo genérico para adicionar esses itens como
   exercícios nativos do catálogo do Fitness. Eles podem ser mantidos como
   metadados próprios do app, mas isso não garante que o Fitness os renderize como
   campos nativos.
2. **WorkoutKit não substitui HealthKit:** WorkoutKit planeja/sincroniza a
   composição; HealthKit registra e armazena o workout e seus samples.
3. **Fitness não é uma API de UI:** a integração pública é feita pelos dados do
   HealthKit. Não há API pública para editar telas, categorias internas ou o banco
   privado do Fitness.
4. **iOS 27:** a documentação pública consultada não declara um tipo novo de
   musculação ou uma API nova de inserção direta no Fitness específica do iOS 27.
   A disponibilidade de `WorkoutKit` começa no iOS 17; o sample de composição
   personalizada exige iOS 18 e watchOS 11 para o fluxo demonstrado.

## Recomendação

Para o My Band, manter a arquitetura atual:

1. Mapear o preset de força para
   `HKWorkoutActivityType.traditionalStrengthTraining`.
2. Criar o workout via `HKWorkoutBuilder`.
3. Associar energia ativa e frequência cardíaca com intervalos coerentes com os
   totais declarados.
4. Usar metadados para identificador da sessão, dispositivo e informações que o
   Fitness/HealthKit não modela como exercício nativo.
5. Avaliar WorkoutKit separadamente apenas para uma futura função de
   “treino planejado” no Apple Watch; não como mecanismo para “inserir exercícios”
   diretamente no Fitness.

## Pesquisa complementar com citações precisas (2026-11-05)

### Fatos documentados pela Apple

* **WorkoutKit é destinado a composições e ao Workout no Apple Watch.** A Apple
  descreve o framework como responsável por criar/visualizar workouts e sincronizar
  composições agendadas ao Workout no Apple Watch; lista `CustomWorkout`,
  `SingleGoalWorkout`, `PacerWorkout` e `SwimBikeRunWorkout`
  ([WorkoutKit](https://developer.apple.com/documentation/workoutkit.md), linhas
  25–44). A mesma página diz que o plano pode ser aberto no Workout do Apple Watch
  e que composições agendadas aparecem em uma área dedicada com o ícone e nome do
  app ([WorkoutKit](https://developer.apple.com/documentation/workoutkit.md),
  linhas 38–44).
* **`CustomWorkout` tem etapas/intervalos, não um modelo de musculação.** A
  inicialização pública recebe atividade, localização, nome, aquecimento, blocos e
  cooldown ([CustomWorkout](https://developer.apple.com/documentation/workoutkit/customworkout.md),
  linhas 25–63). `WorkoutStep` expõe meta, alerta e nome de exibição
  ([WorkoutStep](https://developer.apple.com/documentation/workoutkit/workoutstep.md),
  linhas 25–44), enquanto as metas documentadas são distância, energia, tempo,
  ausência de meta e natação ([WorkoutGoal](https://developer.apple.com/documentation/workoutkit/workoutgoal.md),
  linhas 25–46). Não há campos documentados para série, repetição, carga ou
  resistência; isso sustenta a conclusão de que WorkoutKit estrutura o fluxo do
  treino, não um catálogo de exercícios.
* **`HKWorkout` é o registro de atividade física.** A Apple define `HKWorkout` como
  um sample que armazena uma atividade; cada workout exige um
  `HKWorkoutActivityType`, e samples adicionais podem ser associados depois
  ([HKWorkout](https://developer.apple.com/documentation/healthkit/hkworkout.md),
  linhas 25–45). O workout também é um contêiner para samples detalhados
  ([HKWorkout](https://developer.apple.com/documentation/healthkit/hkworkout.md),
  linhas 45–52).
* **Há dois tipos de força explícitos.** `functionalStrengthTraining` é força
  principalmente com pesos livres e peso corporal; `traditionalStrengthTraining`
  é força principalmente com máquinas ou pesos livres
  ([HKWorkoutActivityType](https://developer.apple.com/documentation/healthkit/hkworkoutactivitytype.md),
  linhas 70–77).
* **No iOS, workouts afetam os anéis.** A Apple diz que no iOS workouts contribuem
  automaticamente para Movimento e Exercício; Exercício usa a duração do workout e
  Movimento usa samples associados de energia ativa. O anel Em Pé também pode ser
  incrementado por horas sobrepostas ([HKWorkout, “Fill the Activity rings”](https://developer.apple.com/documentation/healthkit/hkworkout.md#Fill-the-Activity-rings),
  linhas 54–64).
* **`HKWorkoutBuilder` salva o `HKWorkout`.** O builder coleta samples/eventos e
  `finishWorkout` cria e salva o workout no HealthKit
  ([HKWorkoutBuilder](https://developer.apple.com/documentation/healthkit/hkworkoutbuilder.md),
  linhas 25–39). A API pública inclui adicionar samples, metadados, eventos e
  atividades, encerrar a coleta e finalizar ([HKWorkoutBuilder](https://developer.apple.com/documentation/healthkit/hkworkoutbuilder.md),
  linhas 41–101).
* **`HKWorkoutActivity` representa segmentos.** A Apple dá como exemplos partes de
  um multisport e períodos ativos/de descanso de intervalos
  ([HKWorkoutActivity](https://developer.apple.com/documentation/healthkit/hkworkoutactivity.md),
  linhas 25–37). Os campos públicos são datas, duração, estatísticas, metadados,
  configuração e eventos ([HKWorkoutActivity](https://developer.apple.com/documentation/healthkit/hkworkoutactivity.md),
  linhas 41–79); a documentação não define entidade de exercício com série,
  repetição e carga.
* **Samples associados são medições.** Eles adicionam detalhes como energia,
  distância e frequência cardíaca; não alteram as propriedades-síntese do workout
  ([Adding samples to a workout](https://developer.apple.com/documentation/healthkit/adding-samples-to-a-workout.md),
  linhas 25–50). Portanto, não devem ser tratados como uma API de exercícios
  estruturados de musculação.
* **Escrita é no HealthKit Store e depende de autorização.** A Apple exige
  autorização granular para compartilhar tipos e orienta habilitar HealthKit,
  configurar descrições e chamar `requestAuthorization(toShare:read:)`
  ([Authorizing access to health data](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data.md),
  linhas 25–75). A própria documentação diz que, com permissão, o app salva novos
  samples no HealthKit Store; sem ela, a gravação falha na autorização
  ([Authorizing access to health data](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data.md),
  seção “Check for authorization before saving data”).

### iOS 26/27

* A Apple publicou material oficial para workouts no iPhone/iPad no ciclo do iOS
  26: [Track workouts with HealthKit on iOS and iPadOS — WWDC25,
  sessão 322](https://developer.apple.com/videos/play/wwdc2025/322/). Isso
  confirma o fluxo de sessão/builder no iPhone/iPad; não cria um modelo público de
  séries/repetições/carga.
* O material oficial do iOS/watchOS 27 sobre zonas ([WWDC26, sessão
  207](https://developer.apple.com/videos/play/wwdc2026/207/)) trata zonas de
  frequência cardíaca e potência de ciclismo. `HKWorkoutZone` representa limites
  de uma zona, não exercício, série, repetição ou carga
  ([HKWorkoutZone](https://developer.apple.com/documentation/healthkit/hkworkoutzone.md),
  linhas 1–9 e 25–38).
* Não foi localizada, nas fontes oficiais consultadas, uma API nova do iOS 27 para
  inserir exercícios de musculação individuais no Fitness. Esta é uma conclusão de
  pesquisa da superfície pública; não é uma afirmação sobre APIs privadas.

### Aplicação verificada no repositório

O caminho atual do projeto já coincide com a recomendação Apple:

* `writeWorkouts` instancia `HKWorkoutBuilder`, inicia a coleta, adiciona samples e
  metadados e chama `finishWorkout`
  (`My Band/Health/HealthKitManager.swift:388-509`);
* `WorkoutKind.strengthTraining` é mapeado para
  `.traditionalStrengthTraining`
  (`My Band/Health/HealthKitManager.swift:640-657`).

### Conclusão revisada

**Suportado:** salvar o treino de musculação concluído como workout HealthKit e
fazê-lo participar dos anéis conforme os dados associados.
**Suportado com escopo diferente:** usar WorkoutKit para um plano estruturado,
nomeado e agendado no Workout do Apple Watch.
**Não documentado como API pública:** criar no Fitness registros nativos para
“supino”, “agachamento”, séries, repetições, carga ou progressão.
**Inferência de limite:** não há API pública consultada para editar diretamente a UI
ou o banco privado do Fitness; a superfície pública de escrita é o HealthKit Store.

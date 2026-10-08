# 🛠️ Puntos Dorados — Cambios en el backend (aprobación, vencimiento y lecturas)

Registro de cómo quedó implementado en la API lo que [puntos-dorados-puntos-api.md](puntos-dorados-puntos-api.md) dejaba en la sección 10 ("Lo que sigue"): aprobar o rechazar reconocimientos con puntos y vencer los puntos automáticamente. También recoge las reglas de lectura y de controladores que se confirmaron en la revisión.

> **Fuente:** el resumen de la revisión del equipo (capturas 11 a 20). Los nombres exactos se confirman en el código. La guía de puntos no se modificó.

---

## 1. Concurrencia y transacciones

**El riesgo:** dos acciones sobre el mismo saldo al mismo tiempo. Por ejemplo, una persona canjea puntos en el mismo instante en que el proceso los está venciendo, o dos administradores aprueban el mismo reconocimiento.

| Método | Qué protege |
|---|---|
| `ReviewAsync` (aprobar o rechazar) | Que un reconocimiento se revise y abone **una sola vez**. |
| `ExpireDuePointsAsync` (vencer puntos) | Que el vencimiento no choque con un canje o una asignación de la misma persona. |

### Forma general

```csharp
for (var attempt = 1; attempt <= GoldenPointsConstants.SaveAttempts; attempt++)
{
    try
    {
        return await _transactionHelper.ExecuteWithTransactionAsync<ResponseDto<T>>(
            async unitOfWork =>
            {
                // 1. Leer el estado actual (con seguimiento) y volver a validarlo.
                // 2. Cambiar el estado, mover puntos con GoldenPointsLedger y guardar el historial.
            }
        ) ?? ResponseDtoHelper.CreateErrorResponseDto<T>(GoldenPointsConstants.UnexpectedError);
    }
    catch (InvalidOperationException ex) when (ex.InnerException is DbUpdateException)
    {
        // Choque de row_version o de índice único: el siguiente intento lee el estado nuevo.
    }
}

return ResponseDtoHelper.CreateErrorResponseDto<T>(GoldenPointsConstants.ConcurrentChange);
```

### Por qué funciona

- **Una sola transacción** cambia el estado del reconocimiento, mueve los puntos y guarda el historial. Si algo falla, el helper hace rollback y no quedan datos a medias.
- **Concurrencia optimista:** si otra operación cambió la cuenta (`row_version`) o ya existe el abono (índice único), EF lanza `DbUpdateException`. El helper la envuelve en `InvalidOperationException` y el `catch` con `when` la reconoce. Cualquier otro error sigue subiendo.
- **Cada intento usa un `DbContext` nuevo.** `ExecuteWithTransactionAsync` crea su propio scope de DI (`UnitOfWorkFactory`), así que el reintento no arrastra entidades del intento fallido y lee los datos actuales.
- **El reintento vuelve a validar.** Si el reconocimiento ya no está pendiente, se responde un error de negocio ("ya fue revisado") y no se abona otra vez. El índice `ux_golden_points_transaction_recognition_credit` es la última barrera.

---

## 2. Vencimiento automático

### `ExpireDuePointsAsync`

1. Busca quiénes tienen puntos vencidos con `GetUserIdsWithDuePointsAsync(GoldenClock.Today())`.
2. Recorre las personas **una por una**. Cada una tiene su propia transacción y sus reintentos.
3. Si una persona falla, registra el error y **sigue con la siguiente**.
4. Devuelve un reporte con `UsersProcessed` y `UsersFailed`.

### Ejecución en segundo plano

```csharp
// Program.cs
builder.Services.AddHostedService<GoldenPointsExpirationWorker>();
```

El worker corre `ExpireDuePointsAsync` de forma periódica, sin que nadie lo dispare.

**Reglas para cualquier worker del proyecto:**

| Tema | Regla |
|---|---|
| **Scope** | El worker es singleton y los servicios (`ITransactionExecutorHelper`, `IGoldenPointsService`) son scoped. En cada ejecución se crea un scope con `IServiceScopeFactory.CreateAsyncScope()` y el servicio se resuelve de ahí. Si se inyectan directamente, la app no arranca. |
| **Errores** | Cada ciclo va dentro de un `try/catch` que registra el error y espera al siguiente. En .NET 8, una excepción sin atrapar en un `BackgroundService` **detiene toda la API**. |
| **Cancelación** | El ciclo respeta el `stoppingToken` para que el apagado de la app no quede esperando. |
| **Idempotencia** | Si corre dos veces el mismo día, la segunda no encuentra nada: los lotes vencidos quedan con `remaining_points = 0`. |

### Forma general

```csharp
public class GoldenPointsExpirationWorker(IServiceScopeFactory scopeFactory, ILogger<GoldenPointsExpirationWorker> logger) : BackgroundService
{
    private readonly IServiceScopeFactory _scopeFactory = scopeFactory;
    private readonly ILogger<GoldenPointsExpirationWorker> _logger = logger;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromHours(1));

        do
        {
            try
            {
                await using var scope = _scopeFactory.CreateAsyncScope();
                var service = scope.ServiceProvider.GetRequiredService<IGoldenPointsService>();
                await service.ExpireDuePointsAsync();
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Falló el vencimiento de puntos dorados.");
            }
        }
        while (await timer.WaitForNextTickAsync(stoppingToken));
    }
}
```

> **Cada cuánto corre.** `GoldenClock.Today()` es el día en Colombia. Si el worker corre una vez al día a la medianoche **del servidor** (UTC), en Colombia son las 7 p. m. del día anterior. Los puntos que vencían ese día se quitan casi un día tarde. Correrlo cada hora, como en el ejemplo, evita depender de la hora del servidor. Como el proceso es idempotente, las corridas sin vencimientos solo hacen una consulta.

---

## 3. Lecturas

Ya estaba así en la guía y se confirmó:

- **`IGoldenPointsQueryRepository`** lee con `.AsNoTracking()`. EF no rastrea esas entidades: es más rápido y usa menos memoria.
- **Las sumas se hacen en SQL Server** con `SumAsync` y `MinAsync` (saldo, puntos usados, puntos por vencer, próximo vencimiento). Nunca se trae la lista para sumar en memoria.
- **Se convierte a tipo nullable dentro de la suma**: `SumAsync(t => (int?)t.Points) ?? 0` y `MinAsync(b => (DateOnly?)b.ExpiresDate)`. Sin la conversión, `MinAsync` sobre un conjunto vacío lanza una excepción.
- **Se proyecta a records** (`GoldenPointsSummaryRow`, `GoldenPointsBucketDto`). Las entidades no salen hacia la API.

---

## 4. Controladores

Igual que las reglas 17 y 18 de las convenciones:

- El correo del usuario sale de `MicrosoftUserAuthenticatorHelper`. Sin correo: **401** inmediato.
- Cada acción tiene su propio `try/catch`:
  - `ArgumentException` → **400**
  - `UnauthorizedAccessException` (no es administrador) → **401**
  - `Exception` → **500**

> **"No tiene puntos suficientes".** En el resumen aparece como ejemplo de `ArgumentException` (**400**). Según la regla 9 de las convenciones, los errores de negocio responden **200** con `hasError`. Con un 400, el frontend lo recibe en `catchError`, pasa por `HttpErrorHandlerService` y el facade puede terminar mostrando el mensaje genérico en lugar del real. Revisa en el código cómo responde el saldo insuficiente:
>
> - **Si lanza `ArgumentException`:** cámbialo por `return ResponseDtoHelper.CreateErrorResponseDto<T>(GoldenPointsConstants.InsufficientBalance)` dentro de la lambda (el nombre de la constante es de ejemplo).
> - **Para qué queda `ArgumentException`:** solo para entradas mal formadas, como un body nulo o un id ≤ 0.

---

## 5. Para revisar en el código

| # | Qué | Por qué |
|---|---|---|
| 1 | El worker crea un scope por ejecución y atrapa los errores de cada ciclo. | Sin scope, la app no arranca. Sin `try/catch`, un error detiene la API. |
| 2 | A qué hora corre el vencimiento. | Medianoche UTC son las 7 p. m. en Colombia (ver la nota de la sección 2). |
| 3 | Saldo insuficiente con 200 + `hasError`, no con `ArgumentException`. | Para que el mensaje llegue tal cual al formulario. |
| 4 | Si la API corre en varias instancias, el worker corre en cada una. | No duplica vencimientos (`row_version` + reintentos), pero repite el trabajo. Si se escala, conviene un candado (`sp_getapplock`) o un job de SQL Agent. |

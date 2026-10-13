# 🧩 Puntos Dorados — Editar y eliminar reconocimientos, cargas masivas y dashboard ampliado

Tres cambios, cada uno con su parte de API (.NET 8) y de Angular. Están escritos sobre el código actual de la feature (`.claude/puntos-dorados`).

| Parte | Qué se puede hacer |
|---|---|
| **1. Editar y eliminar** | Quien creó un reconocimiento lo edita o lo elimina **mientras esté Pendiente**. Aprobado o rechazado, ya no. |
| **2. Cargas masivas** | Tres plantillas de Excel: **cargar puntos**, **crear reconocimientos** (pendientes o ya aprobados, con puntos) y **aprobar o rechazar pendientes**. Se descarga la plantilla, se llena, se revisa y se procesa. |
| **3. Dashboard** | Indicador nuevo **Usuarios reconocidos**, **puntos asignados por fecha** (por día o por mes, según el rango) y una **tabla con el estado de cada reconocimiento**. Todo con los filtros de colaboradores, fechas, estado y categoría. |

**Convenciones:** [convenciones-backend-doccb.md](.claude/convenciones-backend-doccb.md):
- `ResponseDto` y errores de negocio con HTTP 200.
- `try/catch` completo en cada acción.
- Repositorio genérico por defecto.
- Validar todo antes de modificar.
- Reintentos por concurrencia (regla 21).
- Filtros con `<select>`.

**Requiere** las guías de [aprobaciones](puntos-dorados-aprobaciones-api.md) (columna `row_version` en `golden_recognition`) y del [dashboard](puntos-dorados-dashboard-api.md).

---

# Parte 1 — Editar y eliminar reconocimientos

## 1.1 Decisiones

| # | Tema | Decisión |
|---|---|---|
| 1 | **¿Quién?** | Solo quien lo creó (`nominator_user_id`). A cualquier otra persona la API le responde "El reconocimiento no existe", sin revelar que existe. |
| 2 | **¿Cuándo?** | Solo **Pendiente**. Aprobado: ya puede estar en el feed y tener puntos abonados. Rechazado: es una decisión final de administración. |
| 3 | **¿Qué se edita?** | Persona reconocida, categoría y motivo, con las mismas reglas de crear: no reconocerse a sí mismo, motivo de 15 a 1.000 caracteres y no tener otro pendiente igual (sin contarse a sí mismo). La visibilidad se conserva si no se envía. |
| 4 | **Categoría inactiva.** | Si se deja la misma, se acepta aunque se haya inactivado después de crear. Si se cambia, la nueva debe estar activa. |
| 5 | **Eliminar.** | Borrado **físico**. Un pendiente no tiene puntos ni reacciones (solo se reacciona en el feed), así que nada lo referencia. |
| 6 | **Se edita mientras administración lo aprueba.** | El `row_version` de `golden_recognition` lo detecta. Un lado gana; el otro reintenta, ve el estado nuevo y responde "ya fue aprobado: no se puede editar". |
| 7 | **En la pantalla.** | En "Reconocimientos que has enviado", los pendientes muestran **Editar** (abre el mismo modal de crear, ya lleno) y **Eliminar** (con confirmación en la tarjeta). |

## 1.2 API

### `Constants/GoldenRecognitionConstants.cs` ✏️ — agrega

```csharp
public const int SaveAttempts = 3;

public const string RecognitionNotFound = "El reconocimiento no existe.";
public const string CannotChangeApproved = "Este reconocimiento ya fue aprobado: no se puede editar ni eliminar.";
public const string CannotChangeRejected = "Este reconocimiento fue rechazado: no se puede editar ni eliminar.";
public const string ConcurrentChange = "El reconocimiento cambió mientras lo editabas (por ejemplo, se aprobó). Recarga la lista.";
```

### `Interfaces/IGoldenRecognitionService.cs` ✏️ — agrega

```csharp
Task<ResponseDto<GoldenRecognitionDto>> UpdateAsync(int recognitionId, CreateGoldenRecognitionDto dto, string currentUserEmail);
Task<ResponseDto<bool>> DeleteAsync(int recognitionId, string currentUserEmail);
```

> El cuerpo de editar es el mismo de crear (`CreateGoldenRecognitionDto`): mismos campos y mismo validador.

### `Services/GoldenRecognitionService.cs` ✏️ — agrega

```csharp
// ── Editar y eliminar (solo quien lo creó, solo pendiente) ───────────

public async Task<ResponseDto<GoldenRecognitionDto>> UpdateAsync(int recognitionId, CreateGoldenRecognitionDto dto, string currentUserEmail)
{
    var errors = new List<string>();
    var draft = GoldenRecognitionValidator.Normalize(dto, errors);

    if (errors.Count > 0)
    {
        return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionDto>(errors);
    }

    // El formulario no envía visibilidad: si no llega, se conserva la que tenía (Normalize la pondría en Pública).
    var keepVisibility = string.IsNullOrWhiteSpace(dto.Visibility);

    for (var attempt = 1; attempt <= GoldenRecognitionConstants.SaveAttempts; attempt++)
    {
        try
        {
            var response = await _transactionHelper.ExecuteWithTransactionAsync<ResponseDto<GoldenRecognitionDto>>(
                async unitOfWork =>
                {
                    var editor = await FindUserByEmailAsync(unitOfWork, currentUserEmail);
                    if (editor is null)
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionDto>(GoldenRecognitionConstants.UserNotRegistered);
                    }

                    // Con seguimiento: se modifica aquí y EF compara su row_version al guardar.
                    var recognition = await unitOfWork.Repository<GoldenRecognition>().GetByIdAsync(recognitionId);
                    var changeError = ChangeError(recognition, editor.Id);
                    if (changeError is not null)
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionDto>(changeError);
                    }

                    var nominee = draft.NomineeUserId > 0
                        ? await unitOfWork.Repository<User>().GetByIdAsync(draft.NomineeUserId)
                        : await FindUserByEmailAsync(unitOfWork, draft.NomineeEmail!);

                    if (nominee is null)
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionDto>(GoldenRecognitionConstants.NomineeNotFound);
                    }

                    if (nominee.Id == editor.Id)
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionDto>(GoldenRecognitionConstants.CannotRecognizeYourself);
                    }

                    // Misma categoría: se acepta aunque se haya inactivado después. Otra: debe estar activa.
                    if (draft.CategoryId != recognition!.CategoryId)
                    {
                        var category = await unitOfWork.Repository<GoldenRecognitionCategory>().GetAsync(c => c.Id == draft.CategoryId);
                        if (category is null)
                        {
                            return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionDto>(GoldenRecognitionConstants.CategoryNotFound);
                        }

                        if (!category.Active)
                        {
                            return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionDto>(GoldenRecognitionConstants.CategoryInactive);
                        }
                    }

                    // Anti-spam, sin contarse a sí mismo.
                    var duplicatePending = await unitOfWork.Repository<GoldenRecognition>().AnyAsync(r =>
                        r.Id != recognitionId &&
                        r.NominatorUserId == editor.Id &&
                        r.NomineeUserId == nominee.Id &&
                        r.CategoryId == draft.CategoryId &&
                        r.Status == GoldenRecognitionStatus.Pending);

                    if (duplicatePending)
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionDto>(GoldenRecognitionConstants.DuplicatePending);
                    }

                    // Todo validado: ahora sí se modifica (el helper guarda aunque se devuelva un error).
                    recognition.NomineeUserId = nominee.Id;
                    recognition.CategoryId = draft.CategoryId;
                    recognition.Reason = draft.Reason;
                    recognition.Visibility = keepVisibility ? recognition.Visibility : draft.Visibility;
                    recognition.UpdatedDate = DateTime.UtcNow;
                    recognition.UpdatedBy = currentUserEmail;

                    return ResponseDtoHelper.CreateSuccessResponseDto(new GoldenRecognitionDto()); // se arma después de guardar
                }
            ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionDto>(GoldenRecognitionConstants.UnexpectedError);

            if (response.HasError)
            {
                return response;
            }

            // El helper ya guardó: se lee con nombres y categoría.
            var row = await _queryRepository.GetRowAsync(recognitionId);
            return row is null
                ? ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionDto>(GoldenRecognitionConstants.UnexpectedError)
                : ResponseDtoHelper.CreateSuccessResponseDto(GoldenRecognitionMapper.ToDto(row, includePoints: false));
        }
        catch (InvalidOperationException ex) when (ex.InnerException is DbUpdateException)
        {
            // Administración lo revisó al mismo tiempo: el siguiente intento ve el estado nuevo.
        }
    }

    return ResponseDtoHelper.CreateErrorResponseDto<GoldenRecognitionDto>(GoldenRecognitionConstants.ConcurrentChange);
}

public async Task<ResponseDto<bool>> DeleteAsync(int recognitionId, string currentUserEmail)
{
    for (var attempt = 1; attempt <= GoldenRecognitionConstants.SaveAttempts; attempt++)
    {
        try
        {
            return await _transactionHelper.ExecuteWithTransactionAsync<ResponseDto<bool>>(
                async unitOfWork =>
                {
                    var user = await FindUserByEmailAsync(unitOfWork, currentUserEmail);
                    if (user is null)
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<bool>(GoldenRecognitionConstants.UserNotRegistered);
                    }

                    var recognitions = unitOfWork.Repository<GoldenRecognition>();
                    var recognition = await recognitions.GetByIdAsync(recognitionId);

                    var changeError = ChangeError(recognition, user.Id);
                    if (changeError is not null)
                    {
                        return ResponseDtoHelper.CreateErrorResponseDto<bool>(changeError);
                    }

                    // Delete por entidad (no DeleteRangeAsync, que guarda por su cuenta). Lleva el row_version.
                    recognitions.Delete(recognition!);
                    return ResponseDtoHelper.CreateSuccessResponseDto(true);
                }
            ) ?? ResponseDtoHelper.CreateErrorResponseDto<bool>(GoldenRecognitionConstants.UnexpectedError);
        }
        catch (InvalidOperationException ex) when (ex.InnerException is DbUpdateException)
        {
            // Se aprobó o rechazó al mismo tiempo: el siguiente intento responde por qué ya no se puede.
        }
    }

    return ResponseDtoHelper.CreateErrorResponseDto<bool>(GoldenRecognitionConstants.ConcurrentChange);
}

/// <summary>Solo quien lo creó, y solo mientras esté pendiente. A otra persona no se le confirma que exista.</summary>
private static string? ChangeError(GoldenRecognition? recognition, int userId) => recognition switch
{
    null => GoldenRecognitionConstants.RecognitionNotFound,
    { NominatorUserId: var owner } when owner != userId => GoldenRecognitionConstants.RecognitionNotFound,
    { Status: GoldenRecognitionStatus.Approved } => GoldenRecognitionConstants.CannotChangeApproved,
    { Status: GoldenRecognitionStatus.Rejected } => GoldenRecognitionConstants.CannotChangeRejected,
    _ => null,
};
```

### `Controllers/GoldenRecognitionsController.cs` ✏️ — agrega

```csharp
/// <summary>Editar un reconocimiento propio y pendiente. PUT {id} (mismo cuerpo que crear)</summary>
[HttpPut("{id:int}")]
[ProducesResponseType(StatusCodes.Status200OK)]
[ProducesResponseType(StatusCodes.Status400BadRequest)]
[ProducesResponseType(StatusCodes.Status401Unauthorized)]
[ProducesResponseType(StatusCodes.Status500InternalServerError)]
public async Task<IActionResult> Update(int id, [FromBody] CreateGoldenRecognitionDto dto)
{
    try
    {
        var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
        if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
        {
            return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
        }

        var response = await _service.UpdateAsync(id, dto, authenticatedUserInfo.Email);
        return Ok(response);
    }
    catch (ArgumentException ex)
    {
        return BadRequest(new { message = ApiResponseConstants.GoldenRecognitionsErrorMessage, error = ex.Message });
    }
    catch (UnauthorizedAccessException)
    {
        return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
    }
    catch (Exception)
    {
        return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenRecognitionsErrorMessage });
    }
}

/// <summary>Eliminar un reconocimiento propio y pendiente. DELETE {id}</summary>
[HttpDelete("{id:int}")]
[ProducesResponseType(StatusCodes.Status200OK)]
[ProducesResponseType(StatusCodes.Status400BadRequest)]
[ProducesResponseType(StatusCodes.Status401Unauthorized)]
[ProducesResponseType(StatusCodes.Status500InternalServerError)]
public async Task<IActionResult> Delete(int id)
{
    try
    {
        var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
        if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
        {
            return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
        }

        var response = await _service.DeleteAsync(id, authenticatedUserInfo.Email);
        return Ok(response);
    }
    catch (ArgumentException ex)
    {
        return BadRequest(new { message = ApiResponseConstants.GoldenRecognitionsErrorMessage, error = ex.Message });
    }
    catch (UnauthorizedAccessException)
    {
        return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
    }
    catch (Exception)
    {
        return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenRecognitionsErrorMessage });
    }
}
```

> `{id:int}` en `PUT` y `DELETE` no choca con las rutas de reacciones (`{id}/reactions/{tipo}`), que tienen más segmentos.

## 1.3 Angular

### `application/paged-list.ts` ✏️ — agrega

```ts
/** Quita un elemento sin recargar (por ejemplo, un reconocimiento eliminado). */
remove(id: number): void {
  const before = this._items().length;
  this._items.update(items => items.filter(item => this.idOf(item) !== id));
  if (this._items().length < before) {
    this._totalCount.update(total => Math.max(0, total - 1));
  }
}
```

### `infrastructure/golden-recognitions.service.ts` ✏️ — agrega

```ts
async update(recognitionId: number, draft: CreateGoldenRecognition): Promise<Observable<GoldenResult<GoldenNomination>>> {
  const headers = await this.authHeaders();

  return this.http.put<GoldenResultDto<GoldenRecognitionDto>>(`${this.apiUrl}/${recognitionId}`, draft, { headers }).pipe(
    map(dto => toResult(dto, toNomination)),
    catchError((error: HttpErrorResponse) => this.errorHandler.handleHttpError(error, 'editar el reconocimiento'))
  );
}

async remove(recognitionId: number): Promise<Observable<GoldenResult<boolean>>> {
  const headers = await this.authHeaders();

  return this.http.delete<GoldenResultDto<boolean>>(`${this.apiUrl}/${recognitionId}`, { headers }).pipe(
    map(dto => toResult(dto, deleted => deleted)),
    catchError((error: HttpErrorResponse) => this.errorHandler.handleHttpError(error, 'eliminar el reconocimiento'))
  );
}
```

### `application/puntos-dorados.fecade.ts` ✏️ — agrega

```ts
async updateRecognition(recognitionId: number, draft: CreateGoldenRecognition): Promise<GoldenResult<GoldenNomination>> {
  const result = await this.runRecognitionRequest(this.recognitionsService.update(recognitionId, draft), 'No se pudo guardar el cambio. Intenta de nuevo.');
  if (!result.hasError) {
    this.notificationService.success('Reconocimiento actualizado.', 'toast');
  }
  return result;
}

async deleteRecognition(recognitionId: number): Promise<GoldenResult<boolean>> {
  const result = await this.runRecognitionRequest(this.recognitionsService.remove(recognitionId), 'No se pudo eliminar el reconocimiento.');
  if (!result.hasError) {
    this.notificationService.info('Reconocimiento eliminado.', 'toast');
  }
  return result;
}
```

### Modal — `shared/postular-nomination-modal/postular-nomination.modal.ts` ✏️

El mismo modal sirve para crear y para editar. Agrega dos entradas y llena la persona elegida al abrir en modo edición:

```ts
/** 'edit' cambia el título y el botón. */
mode = input<'create' | 'edit'>('create');
/** Al editar: la persona que ya estaba reconocida, para mostrarla en el buscador. */
initialNominee = input<GoldenPerson | null>(null);

constructor() {
  effect(() => {
    if (!this.isOpen()) {
      this.selectedNominee.set(null);
      this.reasonLength.set(0);
      return;
    }

    // Al abrir para editar: la persona y el contador del motivo ya vienen del reconocimiento.
    const nominee = this.initialNominee();
    if (nominee) {
      this.selectedNominee.set(nominee);
      this.reasonLength.set((this.form().get('reason')?.value ?? '').length);
    }
  });
}
```

En `postular-nomination.modal.html`, el título y el botón:

```html
<h2>{{ mode() === 'edit' ? 'Editar reconocimiento' : 'Crear reconocimiento' }}</h2>
…
{{ submitting() ? 'Guardando…' : (mode() === 'edit' ? 'Guardar cambios' : 'Enviar reconocimiento') }}
```

### `user/puntos-dorados-user.component.ts` ✏️

```ts
/** null = creando; un id = editando ese reconocimiento. */
readonly editingRecognition = signal<GoldenNomination | null>(null);
/** Confirmación de eliminar abierta en una tarjeta. */
readonly deleteConfirmId = signal<number | null>(null);
readonly deletingId = signal<number | null>(null);
readonly sentErrors = signal<Record<number, string[]>>({});

openPostularModal(): void {
  this.editingRecognition.set(null);
  this.nominationErrors.set([]);
  this.showPostularModal.set(true);
}

/** Abre el mismo modal con el reconocimiento ya lleno. Solo pendientes. */
openEditRecognition(item: GoldenNomination): void {
  if (item.status !== 'Pendiente') {
    return;
  }

  this.editingRecognition.set(item);
  this.nominationErrors.set([]);
  this.nominationForm.reset({
    nomineeEmail: item.nominee.email,
    categoryId: item.categoryId ?? 0,
    reason: item.reason,
  });
  this.showPostularModal.set(true);
}

closePostularModal(): void {
  this.showPostularModal.set(false);
  this.editingRecognition.set(null);
  this.nominationErrors.set([]);
  this.nominationForm.reset({ nomineeEmail: '', categoryId: 0, reason: '' });
}

async submitNomination(): Promise<void> {
  this.nominationForm.markAllAsTouched();
  if (this.nominationForm.invalid || this.submittingNomination()) {
    return;
  }

  const { nomineeEmail, categoryId, reason } = this.nominationForm.getRawValue();
  const draft = { nomineeEmail, categoryId: Number(categoryId), reason: reason.trim() };
  const editing = this.editingRecognition();

  this.submittingNomination.set(true);
  this.nominationErrors.set([]);

  try {
    const result = editing
      ? await this.facade.updateRecognition(editing.id, draft)
      : await this.facade.createRecognition(draft);

    if (result.hasError) {
      // Se queda en el modal: el usuario corrige sin perder lo que escribió.
      this.nominationErrors.set(result.errors);
      return;
    }

    this.closePostularModal();

    if (editing) {
      const updated = result.response;
      this.sentRecognitions.patch(editing.id, () => updated);
    } else {
      await this.sentRecognitions.reload(); // el nuevo aparece primero, como Pendiente
    }
  } finally {
    this.submittingNomination.set(false);
  }
}

askDeleteRecognition(id: number): void {
  this.sentErrors.update(({ [id]: _removed, ...rest }) => rest);
  this.deleteConfirmId.set(id);
}

cancelDeleteRecognition(): void {
  this.deleteConfirmId.set(null);
}

async confirmDeleteRecognition(id: number): Promise<void> {
  if (this.deletingId() !== null) {
    return;
  }

  this.deletingId.set(id);

  try {
    const result = await this.facade.deleteRecognition(id);
    this.deleteConfirmId.set(null);

    if (result.hasError) {
      this.sentErrors.update(all => ({ ...all, [id]: result.errors }));
      return;
    }

    this.sentRecognitions.remove(id);
  } finally {
    this.deletingId.set(null);
  }
}
```

> **Categoría inactiva al editar.** El selector del modal muestra solo las activas. Si la categoría original se inactivó, el selector queda en "Selecciona una categoría" y hay que elegir otra: es lo que pide la regla 4.

### `user/puntos-dorados-user.component.html` ✏️

El modal recibe el modo y la persona:

```html
<app-postular-nomination-modal
  [isOpen]="showPostularModal()"
  [mode]="editingRecognition() ? 'edit' : 'create'"
  [initialNominee]="editingRecognition()?.nominee ?? null"
  [form]="nominationForm"
  [currentUserEmail]="userEmail()"
  [categories]="activeCategories()"
  [submitting]="submittingNomination()"
  [errors]="nominationErrors()"
  (close)="closePostularModal()"
  (submit)="submitNomination()">
</app-postular-nomination-modal>
```

En cada tarjeta de "Reconocimientos que has enviado", después del `<footer class="pd-sent__meta">`:

```html
@if (item.status === 'Pendiente') {
  @if (deleteConfirmId() === item.id) {
    <div class="pd-sent__confirm" role="alertdialog" aria-label="Confirmar eliminación">
      <span>¿Eliminar este reconocimiento? No se puede deshacer.</span>
      <button type="button" class="btn-secondary" [disabled]="deletingId() === item.id" (click)="cancelDeleteRecognition()">Volver</button>
      <button type="button" class="pd-sent__danger" [disabled]="deletingId() === item.id" (click)="confirmDeleteRecognition(item.id)">
        {{ deletingId() === item.id ? 'Eliminando…' : 'Eliminar' }}
      </button>
    </div>
  } @else {
    <div class="pd-sent__actions">
      <button type="button" class="pd-sent__action" (click)="openEditRecognition(item)">
        <i class="fa-solid fa-pen" aria-hidden="true"></i> Editar
      </button>
      <button type="button" class="pd-sent__action pd-sent__action--danger" (click)="askDeleteRecognition(item.id)">
        <i class="fa-solid fa-trash-can" aria-hidden="true"></i> Eliminar
      </button>
    </div>
  }
}

@for (error of sentErrors()[item.id] ?? []; track error) {
  <p class="pd-sent__error" role="alert">{{ error }}</p>
}
```

### `user/puntos-dorados-user.component.scss` ✏️ — agrega

```scss
.pd-sent__actions,
.pd-sent__confirm {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: flex-end;
  gap: 0.5rem;
  margin-top: 0.75rem;
}

.pd-sent__confirm {
  padding: 0.6rem 0.75rem;
  border-radius: 0.75rem;
  background: color-mix(in srgb, var(--bs-danger) 8%, var(--bs-body-bg));

  span {
    flex: 1 1 14rem;
    font-size: 0.85rem;
    font-weight: 600;
  }
}

.pd-sent__action {
  padding: 0.3rem 0.8rem;
  border: 1px solid var(--bs-border-color);
  border-radius: 999px;
  background: var(--bs-body-bg);
  font-size: 0.8rem;
  font-weight: 600;

  &--danger {
    color: var(--bs-danger);
  }
}

.pd-sent__danger {
  padding: 0.35rem 0.9rem;
  border: 0;
  border-radius: 999px;
  background: var(--bs-danger);
  color: var(--bs-white);
  font-weight: 600;
}

.pd-sent__error {
  margin: 0.5rem 0 0;
  color: var(--bs-danger);
  font-size: 0.85rem;
}
```

---

# Parte 2 — Cargas masivas con plantilla de Excel

## 2.1 Las tres plantillas

| Plantilla | Para qué | Columnas (los encabezados no distinguen mayúsculas ni tildes) |
|---|---|---|
| **Puntos** | Asignar puntos a muchas personas a la vez (bonos, campañas). | `cedula`, `correo` (una de las dos), `puntos`, `concepto`, `vence` (opcional, `aaaa-mm-dd`) |
| **Reconocimientos** | Crear reconocimientos en bloque; pueden entrar ya **aprobados y con puntos**. | `cedula`, `correo`, `categoria` (nombre), `motivo`, `visibilidad` (opcional: Publica/Privada), `estado` (opcional: Pendiente/Aprobada), `puntos` (solo si Aprobada) |
| **Aprobar pendientes** | Aprobar o rechazar muchos pendientes. **Se descarga ya llena** con los pendientes. | `id`, `reconocido`, `correo`, `categoria`, `motivo`, `creado` (informativas), `decision` (Aprobar / Rechazar / vacía), `puntos`, `comentario` |

Cada plantilla trae una hoja **Instrucciones** con lo que acepta cada columna.

## 2.2 Decisiones

| # | Tema | Decisión |
|---|---|---|
| 1 | **¿Quién lee el Excel?** | El **navegador**, con la librería `xlsx` que ya usa la pantalla. A la API llegan filas en JSON: no hace falta una librería de Excel en .NET, y las plantillas también se generan en el navegador. |
| 2 | **Revisar antes de aplicar.** | Al elegir el archivo, la API lo **revisa sin guardar nada** (`dryRun=true`) y responde los errores fila por fila. "Procesar" se habilita solo si no hay errores. |
| 3 | **Todo o nada.** | Se procesa en **una sola transacción**. Si una fila falla al aplicar (por ejemplo, un dato que cambió entre la revisión y el clic), no se aplica ninguna. Así nunca queda una carga a medias que obligue a revisar qué entró y qué no antes de volver a subirla. |
| 4 | **Doble clic o recarga.** | Cada archivo lleva un `requestId`. La tabla `golden_bulk_load` lo guarda con índice único: si el mismo envío llega dos veces, la segunda responde "ya se procesó" y no abona otra vez. |
| 5 | **Trazabilidad.** | Cada carga queda en `golden_bulk_load` (tipo, archivo, filas, quién y cuándo). Los movimientos de puntos y los reconocimientos que crea guardan `bulk_load_id`: se puede saber qué entró con cada archivo. |
| 6 | **Personas.** | Por **cédula** o por **correo**. Si vienen las dos y no son de la misma persona, la fila da error, porque es justo la señal de una equivocación. Los puntos de la cédula y espacios se ignoran. |
| 7 | **Aprobar pendientes es por id, no por cédula.** | Una persona puede tener varios pendientes: con la cédula no se sabe cuál aprobar. Por eso la plantilla se descarga con los pendientes reales y su `id`, y solo se llenan `decision` y `puntos`. **Reemplaza** la carga de prueba de hoy ("cédula y puntos"). |
| 8 | **¿Quién reconoce en la carga de reconocimientos?** | Quien sube el archivo (administración). Por eso no puede reconocerse a sí misma, como en la asignación manual. |
| 9 | **Límites.** | Hasta **1.000 filas** por archivo y las mismas reglas que la operación individual: puntos de 1 a 100.000, concepto de 5 a 300 caracteres, motivo de 15 a 1.000, vencimiento máximo de 24 meses y por defecto de 12. |
| 10 | **Permisos.** | Comentados, igual que aprobaciones (sección 9 de [esa guía](puntos-dorados-aprobaciones-api.md)). |

## 2.3 Base de datos — `Persistence/Scripts SQL/GoldenBulkLoads.sql`

```sql
/* =====================================================================
   Puntos Dorados — cargas masivas
   Base de datos: DB · Esquema: dbo
   Requiere: GoldenPointsRecognitions.sql y GoldenPointsLedger.sql
   El script se puede ejecutar varias veces: solo crea lo que no existe.
   ===================================================================== */
USE [DB];
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'dbo.golden_bulk_load', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.golden_bulk_load
    (
        id           INT              IDENTITY(1, 1) NOT NULL,
        load_type    VARCHAR(20)      NOT NULL,      -- POINTS | RECOGNITIONS | APPROVALS
        request_id   UNIQUEIDENTIFIER NOT NULL,      -- un envío = una carga (doble clic)
        file_name    NVARCHAR(260)    NULL,
        total_rows   INT              NOT NULL,
        created_date DATETIME2(0)     NOT NULL CONSTRAINT df_golden_bulk_load_created_date DEFAULT (SYSUTCDATETIME()),
        created_by   NVARCHAR(150)    NOT NULL,

        CONSTRAINT pk_golden_bulk_load PRIMARY KEY CLUSTERED (id),
        CONSTRAINT ck_golden_bulk_load_type CHECK (load_type IN ('POINTS', 'RECOGNITIONS', 'APPROVALS')),
        CONSTRAINT ck_golden_bulk_load_rows CHECK (total_rows > 0)
    );

    CREATE UNIQUE INDEX ux_golden_bulk_load_request ON dbo.golden_bulk_load (request_id);
END;
GO

/* Qué movimientos y qué reconocimientos entraron con cada carga. */
IF COL_LENGTH(N'dbo.golden_points_transaction', N'bulk_load_id') IS NULL
    ALTER TABLE dbo.golden_points_transaction
        ADD bulk_load_id INT NULL
            CONSTRAINT fk_golden_points_transaction_bulk_load REFERENCES dbo.golden_bulk_load (id);
GO

IF COL_LENGTH(N'dbo.golden_recognition', N'bulk_load_id') IS NULL
    ALTER TABLE dbo.golden_recognition
        ADD bulk_load_id INT NULL
            CONSTRAINT fk_golden_recognition_bulk_load REFERENCES dbo.golden_bulk_load (id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'ix_golden_points_transaction_bulk_load' AND object_id = OBJECT_ID(N'dbo.golden_points_transaction'))
    CREATE INDEX ix_golden_points_transaction_bulk_load
        ON dbo.golden_points_transaction (bulk_load_id)
        WHERE bulk_load_id IS NOT NULL;
GO
```

> **El trigger del libro** (`tr_golden_points_transaction_immutable`) bloquea `UPDATE` y `DELETE` de filas. Agregar una columna (`ALTER TABLE`) no lo dispara.

## 2.4 Dominio y EF

### `Enum/GoldenBulkLoadType.cs`

```csharp
namespace DOCCB.Domain.Enum
{
    public enum GoldenBulkLoadType
    {
        Points = 1,
        Recognitions = 2,
        Approvals = 3,
    }
}
```

### `Entities/GoldenBulkLoad.cs`

```csharp
using DOCCB.Domain.Enum;

namespace DOCCB.Domain.Entities
{
    /// <summary>Un archivo procesado en una carga masiva.</summary>
    public class GoldenBulkLoad
    {
        public int Id { get; set; }
        public GoldenBulkLoadType LoadType { get; set; }
        public Guid RequestId { get; set; }
        public string? FileName { get; set; }
        public int TotalRows { get; set; }
        public DateTime CreatedDate { get; set; }
        public string CreatedBy { get; set; } = string.Empty;
    }
}
```

### `GoldenPointsTransaction.cs` y `GoldenRecognition.cs` ✏️ — agrega en las dos

```csharp
public int? BulkLoadId { get; set; }
public GoldenBulkLoad? BulkLoad { get; set; }
```

### `Configurations/GoldenBulkLoadConfiguration.cs`

```csharp
using DOCCB.Domain.Entities;
using DOCCB.Domain.Enum;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace DOCCB.Infraestructure.Configurations
{
    public class GoldenBulkLoadConfiguration : IEntityTypeConfiguration<GoldenBulkLoad>
    {
        public void Configure(EntityTypeBuilder<GoldenBulkLoad> builder)
        {
            builder.ToTable("golden_bulk_load", "dbo");

            builder.HasKey(x => x.Id).HasName("pk_golden_bulk_load");

            builder.Property(x => x.Id).HasColumnName("id");
            builder.Property(x => x.RequestId).HasColumnName("request_id");
            builder.Property(x => x.FileName).HasColumnName("file_name").HasMaxLength(260);
            builder.Property(x => x.TotalRows).HasColumnName("total_rows");
            builder.Property(x => x.CreatedDate).HasColumnName("created_date").HasColumnType("datetime2(0)");
            builder.Property(x => x.CreatedBy).HasColumnName("created_by").HasMaxLength(150).IsRequired();

            builder.Property(x => x.LoadType)
                .HasColumnName("load_type")
                .HasMaxLength(20)
                .IsUnicode(false)
                .HasConversion(
                    type => type.ToString().ToUpperInvariant(),
                    code => Enum.Parse<GoldenBulkLoadType>(code, true));

            builder.HasIndex(x => x.RequestId).IsUnique().HasDatabaseName("ux_golden_bulk_load_request");
        }
    }
}
```

### `GoldenPointsTransactionConfiguration.cs` y `GoldenRecognitionConfiguration.cs` ✏️ — agrega

```csharp
builder.Property(x => x.BulkLoadId).HasColumnName("bulk_load_id");

builder.HasOne(x => x.BulkLoad)
    .WithMany()
    .HasForeignKey(x => x.BulkLoadId)
    .HasConstraintName("fk_golden_points_transaction_bulk_load") // en la de reconocimientos: fk_golden_recognition_bulk_load
    .OnDelete(DeleteBehavior.Restrict);
```

### `DOCCbDbContext.cs` ✏️

```csharp
public DbSet<GoldenBulkLoad> GoldenBulkLoads { get; set; }
```

### `Helpers/GoldenPointsLedger.cs` ✏️ — el abono puede venir de una carga

Agrega dos parámetros opcionales al record y úsalos al crear el movimiento. Así, cuando la carga crea el reconocimiento **en la misma transacción**, EF pone el `recognition_id` y el `bulk_load_id` al guardar (los dos `Id` todavía son 0 dentro de la lambda):

```csharp
public sealed record GoldenPointsCredit(
    int UserId,
    int Points,
    GoldenPointsSource Source,
    string Concept,
    DateOnly ExpiresDate,
    string CreatedBy,
    int? RecognitionId = null,
    Guid? RequestId = null,
    GoldenRecognition? Recognition = null,  // nuevo: reconocimiento creado en la misma transacción
    GoldenBulkLoad? BulkLoad = null);       // nuevo: la carga masiva que lo originó
```

En `CreditAsync`, dentro de `new GoldenPointsTransaction { … }`:

```csharp
Recognition = credit.Recognition,
BulkLoad = credit.BulkLoad,
```

## 2.5 Constantes y DTOs

### `Constants/GoldenBulkLoadConstants.cs`

```csharp
namespace DOCCB.Application.Features.GoldenPoints.Application.Constants
{
    public static class GoldenBulkLoadConstants
    {
        public const int MaxRows = 1_000;
        public const int SaveAttempts = 3;

        public const string RequestIdRequired = "Falta el identificador de la carga. Vuelve a seleccionar el archivo.";
        public const string NoRows = "El archivo no tiene filas para procesar.";
        public const string TooManyRows = "El archivo admite hasta 1.000 filas. Divídelo en varios.";

        public const string IdentifierRequired = "Escribe la cédula o el correo de la persona.";
        public const string UserNotFound = "No existe una persona registrada con esa cédula o correo.";
        public const string IdentifierMismatch = "La cédula y el correo no son de la misma persona.";
        public const string CannotAssignToYourself = "No puedes asignarte puntos ni reconocerte a ti mismo.";
        public const string PointsInvalid = "Los puntos deben ser un número entero entre 1 y 100.000.";
        public const string ConceptInvalid = "El concepto debe tener entre 5 y 300 caracteres.";
        public const string ExpirationInvalid = "El vencimiento debe ser posterior a hoy y máximo 24 meses después.";

        public const string CategoryRequired = "Escribe la categoría.";
        public const string CategoryNotFound = "La categoría no existe o está inactiva.";
        public const string ReasonInvalid = "El motivo debe tener entre 15 y 1.000 caracteres.";
        public const string VisibilityInvalid = "La visibilidad debe ser Publica o Privada.";
        public const string StatusInvalid = "El estado debe ser Pendiente o Aprobada.";
        public const string ApprovalPointsInvalid = "Los puntos deben ser un número entero entre 0 y 100.000.";
        public const string PointsOnlyWhenApproved = "Los puntos solo se asignan a reconocimientos aprobados.";
        public const string DuplicatePending = "Ya hay un reconocimiento pendiente igual (misma persona y categoría).";

        public const string RecognitionIdRequired = "Falta el id del reconocimiento.";
        public const string DuplicateRecognitionRow = "Este reconocimiento ya está en otra fila del archivo.";
        public const string RecognitionNotFound = "El reconocimiento no existe.";
        public const string RecognitionNotPending = "Este reconocimiento ya fue revisado.";
        public const string DecisionInvalid = "La decisión debe ser Aprobar, Rechazar o quedar vacía.";
        public const string CommentTooLong = "El comentario admite hasta 500 caracteres.";
    }
}
```

### `Dtos/GoldenBulkLoadDtos.cs`

```csharp
namespace DOCCB.Application.Features.GoldenPoints.Application.Dtos
{
    /// <summary>Un archivo ya leído en el navegador.</summary>
    public class GoldenBulkRequestDto<TRow>
    {
        /// <summary>GUID por archivo: el mismo envío dos veces no se procesa dos veces.</summary>
        public Guid RequestId { get; set; }
        public string? FileName { get; set; }
        public List<TRow> Rows { get; set; } = [];
    }

    public class GoldenBulkPointsRowDto
    {
        /// <summary>Fila en el Excel (para los mensajes de error).</summary>
        public int RowNumber { get; set; }
        public string? Identification { get; set; }
        public string? Email { get; set; }
        public int Points { get; set; }
        public string? Concept { get; set; }
        /// <summary>Vacío = vence en 12 meses.</summary>
        public DateOnly? ExpiresDate { get; set; }
    }

    public class GoldenBulkRecognitionRowDto
    {
        public int RowNumber { get; set; }
        public string? Identification { get; set; }
        public string? Email { get; set; }
        /// <summary>Nombre de la categoría.</summary>
        public string? Category { get; set; }
        public string? Reason { get; set; }
        /// <summary>Publica (por defecto) | Privada</summary>
        public string? Visibility { get; set; }
        /// <summary>Pendiente (por defecto) | Aprobada</summary>
        public string? Status { get; set; }
        /// <summary>Solo si Aprobada. Vacío o 0 = sin puntos.</summary>
        public int? Points { get; set; }
    }

    public class GoldenBulkApprovalRowDto
    {
        public int RowNumber { get; set; }
        public int RecognitionId { get; set; }
        /// <summary>Aprobar | Rechazar | vacío (la fila no se toca)</summary>
        public string? Decision { get; set; }
        public int? Points { get; set; }
        public string? Comment { get; set; }
    }

    public class GoldenBulkRowErrorDto
    {
        public int RowNumber { get; set; }
        public string Message { get; set; } = string.Empty;
    }

    public class GoldenBulkResultDto
    {
        /// <summary>true = solo se revisó; no se guardó nada.</summary>
        public bool DryRun { get; set; }
        /// <summary>Este requestId ya se había procesado: no se volvió a aplicar.</summary>
        public bool AlreadyProcessed { get; set; }
        /// <summary>Id de golden_bulk_load cuando se procesó.</summary>
        public int? LoadId { get; set; }
        public int TotalRows { get; set; }
        /// <summary>Filas sin errores.</summary>
        public int ValidRows { get; set; }
        /// <summary>Filas aplicadas (0 si hubo errores o fue revisión).</summary>
        public int ProcessedRows { get; set; }
        /// <summary>Filas que no se tocan (aprobar pendientes con la decisión vacía).</summary>
        public int SkippedRows { get; set; }
        public int TotalPoints { get; set; }
        public List<GoldenBulkRowErrorDto> Errors { get; set; } = [];
    }

    /// <summary>Un pendiente para la plantilla "Aprobar pendientes".</summary>
    public class GoldenBulkPendingRowDto
    {
        public int RecognitionId { get; set; }
        public string NomineeName { get; set; } = string.Empty;
        public string NomineeEmail { get; set; } = string.Empty;
        public string NominatorName { get; set; } = string.Empty;
        public string Category { get; set; } = string.Empty;
        public string Reason { get; set; } = string.Empty;
        public DateTime CreatedAt { get; set; }
    }
}
```

## 2.6 Servicio — `Services/GoldenBulkLoadService.cs`

**¿Repositorio propio?** No. Las lecturas son filtros con `Contains` (personas, categorías y reconocimientos de las filas), y la plantilla de pendientes es una proyección ordenada con `selector`. El repositorio genérico alcanza.

Patrón de los tres métodos:
1. **Formato de cada fila**, sin base de datos.
2. **En la transacción:** ¿ya se procesó este `requestId`?
3. **Personas, categorías y reconocimientos** de todas las filas, en pocas consultas.
4. **Si hay errores o es revisión:** se responde **sin modificar nada**.
5. **Si todo está bien:** se crea la carga y se aplican las filas.

```csharp
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.Common.Application.Interfaces; // ITransactionExecutorHelper (ajusta al namespace real)
using DOCCB.Application.Features.GoldenPoints.Application.Constants;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using DOCCB.Application.Features.GoldenPoints.Application.Helpers;
using DOCCB.Application.Features.GoldenPoints.Application.Interfaces;
using DOCCB.Domain.Entities;
using DOCCB.Domain.Enum;
using Microsoft.EntityFrameworkCore; // Include, DbUpdateException

namespace DOCCB.Application.Features.GoldenPoints.Application.Services
{
    public class GoldenBulkLoadService(ITransactionExecutorHelper transactionHelper) : IGoldenBulkLoadService
    {
        private readonly ITransactionExecutorHelper _transactionHelper = transactionHelper;

        // ── 1. Puntos ───────────────────────────────────────────────────

        public async Task<ResponseDto<GoldenBulkResultDto>> ProcessPointsAsync(
            GoldenBulkRequestDto<GoldenBulkPointsRowDto> request, bool dryRun, string currentUserEmail)
        {
            var requestError = ValidateRequest(request.RequestId, request.Rows.Count);
            if (requestError is not null)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenBulkResultDto>(requestError);
            }

            var today = GoldenClock.Today();
            var formatErrors = new List<GoldenBulkRowErrorDto>();
            var drafts = new List<PointsDraft>();

            foreach (var row in request.Rows)
            {
                var messages = new List<string>();
                var key = UserKey.From(row.Identification, row.Email);
                if (key.IsEmpty)
                {
                    messages.Add(GoldenBulkLoadConstants.IdentifierRequired);
                }

                if (row.Points < 1 || row.Points > GoldenPointsConstants.MaxPointsPerAssignment)
                {
                    messages.Add(GoldenBulkLoadConstants.PointsInvalid);
                }

                var concept = row.Concept?.Trim() ?? string.Empty;
                if (concept.Length < GoldenPointsConstants.ConceptMinLength || concept.Length > GoldenPointsConstants.ConceptMaxLength)
                {
                    messages.Add(GoldenBulkLoadConstants.ConceptInvalid);
                }

                var expires = row.ExpiresDate ?? today.AddMonths(GoldenPointsConstants.DefaultExpirationMonths);
                if (expires <= today || expires > today.AddMonths(GoldenPointsConstants.MaxExpirationMonths))
                {
                    messages.Add(GoldenBulkLoadConstants.ExpirationInvalid);
                }

                if (messages.Count > 0)
                {
                    formatErrors.Add(RowError(row.RowNumber, messages));
                }
                else
                {
                    drafts.Add(new PointsDraft(row.RowNumber, key, row.Points, concept, expires));
                }
            }

            for (var attempt = 1; attempt <= GoldenBulkLoadConstants.SaveAttempts; attempt++)
            {
                try
                {
                    GoldenBulkLoad? load = null;

                    var response = await _transactionHelper.ExecuteWithTransactionAsync<ResponseDto<GoldenBulkResultDto>>(
                        async unitOfWork =>
                        {
                            var previous = await FindLoadAsync(unitOfWork, request.RequestId);
                            if (previous is not null)
                            {
                                return ResponseDtoHelper.CreateSuccessResponseDto(AlreadyProcessed(previous));
                            }

                            var admin = await FindUserByEmailAsync(unitOfWork, currentUserEmail);
                            if (admin is null)
                            {
                                return ResponseDtoHelper.CreateErrorResponseDto<GoldenBulkResultDto>(GoldenRecognitionConstants.UserNotRegistered);
                            }

                            // Permisos (pendiente, guía de aprobaciones, sección 9): if (!await CanReviewAsync(currentUserEmail)) throw new UnauthorizedAccessException();

                            var directory = await UserDirectory.LoadAsync(unitOfWork, drafts.Select(draft => draft.Key));
                            var errors = new List<GoldenBulkRowErrorDto>(formatErrors);
                            var ready = new List<(PointsDraft Draft, User User)>();

                            foreach (var draft in drafts)
                            {
                                var (user, error) = directory.Find(draft.Key);
                                if (user is null)
                                {
                                    errors.Add(RowError(draft.RowNumber, error!));
                                }
                                else if (user.Id == admin.Id)
                                {
                                    errors.Add(RowError(draft.RowNumber, GoldenBulkLoadConstants.CannotAssignToYourself));
                                }
                                else
                                {
                                    ready.Add((draft, user));
                                }
                            }

                            var result = Summary(request.Rows.Count, ready.Count, errors, ready.Sum(item => item.Draft.Points), dryRun);

                            // Revisión, o algo falló: no se cambia nada (todo o nada).
                            if (dryRun || errors.Count > 0)
                            {
                                return ResponseDtoHelper.CreateSuccessResponseDto(result);
                            }

                            load = await AddLoadAsync(unitOfWork, GoldenBulkLoadType.Points, request, currentUserEmail);

                            foreach (var (draft, user) in ready)
                            {
                                await GoldenPointsLedger.CreditAsync(unitOfWork, new GoldenPointsCredit(
                                    user.Id,
                                    draft.Points,
                                    GoldenPointsSource.Manual,
                                    draft.Concept,
                                    draft.ExpiresDate,
                                    currentUserEmail,
                                    BulkLoad: load));
                            }

                            result.ProcessedRows = ready.Count;
                            return ResponseDtoHelper.CreateSuccessResponseDto(result);
                        }
                    ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenBulkResultDto>(GoldenRecognitionConstants.UnexpectedError);

                    return WithLoadId(response, load);
                }
                catch (InvalidOperationException ex) when (ex.InnerException is DbUpdateException)
                {
                    // Saldo cambiado al mismo tiempo (row_version) o el mismo requestId en otra petición (índice único).
                    // El siguiente intento lee de nuevo; si fue el requestId, responde "ya se procesó".
                }
            }

            return ResponseDtoHelper.CreateErrorResponseDto<GoldenBulkResultDto>(GoldenPointsConstants.ConcurrentChange);
        }

        // ── 2. Reconocimientos (crear, pendientes o aprobados) ──────────

        public async Task<ResponseDto<GoldenBulkResultDto>> ProcessRecognitionsAsync(
            GoldenBulkRequestDto<GoldenBulkRecognitionRowDto> request, bool dryRun, string currentUserEmail)
        {
            var requestError = ValidateRequest(request.RequestId, request.Rows.Count);
            if (requestError is not null)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenBulkResultDto>(requestError);
            }

            var formatErrors = new List<GoldenBulkRowErrorDto>();
            var drafts = new List<RecognitionDraft>();

            foreach (var row in request.Rows)
            {
                var messages = new List<string>();
                var key = UserKey.From(row.Identification, row.Email);
                if (key.IsEmpty)
                {
                    messages.Add(GoldenBulkLoadConstants.IdentifierRequired);
                }

                var category = row.Category?.Trim() ?? string.Empty;
                if (category.Length == 0)
                {
                    messages.Add(GoldenBulkLoadConstants.CategoryRequired);
                }

                var reason = row.Reason?.Trim() ?? string.Empty;
                if (reason.Length < GoldenRecognitionConstants.ReasonMinLength || reason.Length > GoldenRecognitionConstants.ReasonMaxLength)
                {
                    messages.Add(GoldenBulkLoadConstants.ReasonInvalid);
                }

                if (!GoldenRecognitionCodes.TryParseVisibility(row.Visibility, out var visibility))
                {
                    messages.Add(GoldenBulkLoadConstants.VisibilityInvalid);
                }

                var status = ParseBulkStatus(row.Status);
                if (status is null)
                {
                    messages.Add(GoldenBulkLoadConstants.StatusInvalid);
                }

                var points = row.Points ?? 0;
                if (status == GoldenRecognitionStatus.Pending && points > 0)
                {
                    messages.Add(GoldenBulkLoadConstants.PointsOnlyWhenApproved);
                }
                else if (points < 0 || points > GoldenPointsConstants.MaxPointsPerAssignment)
                {
                    messages.Add(GoldenBulkLoadConstants.ApprovalPointsInvalid);
                }

                if (messages.Count > 0)
                {
                    formatErrors.Add(RowError(row.RowNumber, messages));
                }
                else
                {
                    drafts.Add(new RecognitionDraft(row.RowNumber, key, category, reason, visibility, status!.Value, points));
                }
            }

            for (var attempt = 1; attempt <= GoldenBulkLoadConstants.SaveAttempts; attempt++)
            {
                try
                {
                    GoldenBulkLoad? load = null;

                    var response = await _transactionHelper.ExecuteWithTransactionAsync<ResponseDto<GoldenBulkResultDto>>(
                        async unitOfWork =>
                        {
                            var previous = await FindLoadAsync(unitOfWork, request.RequestId);
                            if (previous is not null)
                            {
                                return ResponseDtoHelper.CreateSuccessResponseDto(AlreadyProcessed(previous));
                            }

                            var admin = await FindUserByEmailAsync(unitOfWork, currentUserEmail);
                            if (admin is null)
                            {
                                return ResponseDtoHelper.CreateErrorResponseDto<GoldenBulkResultDto>(GoldenRecognitionConstants.UserNotRegistered);
                            }

                            // Permisos (pendiente): if (!await CanReviewAsync(currentUserEmail)) throw new UnauthorizedAccessException();

                            var directory = await UserDirectory.LoadAsync(unitOfWork, drafts.Select(draft => draft.Key));

                            // Categorías activas por nombre (la intercalación de SQL Server no distingue mayúsculas; aquí tampoco).
                            var names = drafts.Select(draft => draft.CategoryName).Distinct().ToList();
                            var categories = (await unitOfWork.Repository<GoldenRecognitionCategory>()
                                    .GetListAsync(c => c.Active && names.Contains(c.Name)))
                                .ToDictionary(c => c.Name, StringComparer.OrdinalIgnoreCase);

                            // Los pendientes que ya tiene quien sube el archivo, en una sola consulta (no una por fila).
                            var existingPending = (await unitOfWork.Repository<GoldenRecognition>()
                                    .GetListAsync(r => r.NominatorUserId == admin.Id && r.Status == GoldenRecognitionStatus.Pending))
                                .Select(r => (r.NomineeUserId, r.CategoryId))
                                .ToHashSet();

                            var errors = new List<GoldenBulkRowErrorDto>(formatErrors);
                            var ready = new List<(RecognitionDraft Draft, User User, GoldenRecognitionCategory Category)>();
                            var pendingInFile = new HashSet<(int UserId, int CategoryId)>();

                            foreach (var draft in drafts)
                            {
                                var (user, error) = directory.Find(draft.Key);
                                if (user is null)
                                {
                                    errors.Add(RowError(draft.RowNumber, error!));
                                    continue;
                                }

                                if (user.Id == admin.Id)
                                {
                                    errors.Add(RowError(draft.RowNumber, GoldenBulkLoadConstants.CannotAssignToYourself));
                                    continue;
                                }

                                if (!categories.TryGetValue(draft.CategoryName, out var category))
                                {
                                    errors.Add(RowError(draft.RowNumber, GoldenBulkLoadConstants.CategoryNotFound));
                                    continue;
                                }

                                // Anti-spam para pendientes: ni en la base de datos ni repetido en el archivo.
                                if (draft.Status == GoldenRecognitionStatus.Pending)
                                {
                                    var duplicate = !pendingInFile.Add((user.Id, category.Id)) ||
                                        existingPending.Contains((user.Id, category.Id));

                                    if (duplicate)
                                    {
                                        errors.Add(RowError(draft.RowNumber, GoldenBulkLoadConstants.DuplicatePending));
                                        continue;
                                    }
                                }

                                ready.Add((draft, user, category));
                            }

                            var result = Summary(request.Rows.Count, ready.Count, errors, ready.Sum(item => item.Draft.Points), dryRun);

                            if (dryRun || errors.Count > 0)
                            {
                                return ResponseDtoHelper.CreateSuccessResponseDto(result);
                            }

                            load = await AddLoadAsync(unitOfWork, GoldenBulkLoadType.Recognitions, request, currentUserEmail);
                            var now = DateTime.UtcNow;
                            var expires = GoldenClock.Today().AddMonths(GoldenPointsConstants.DefaultExpirationMonths);

                            foreach (var (draft, user, category) in ready)
                            {
                                var approved = draft.Status == GoldenRecognitionStatus.Approved;

                                var recognition = new GoldenRecognition
                                {
                                    NomineeUserId = user.Id,
                                    NominatorUserId = admin.Id,
                                    CategoryId = category.Id,
                                    Reason = draft.Reason,
                                    Visibility = draft.Visibility,
                                    Status = draft.Status,
                                    PointsAssigned = approved && draft.Points > 0 ? draft.Points : null,
                                    ReviewedDate = approved ? now : null,
                                    ReviewedBy = approved ? currentUserEmail : null,
                                    CreatedDate = now,
                                    CreatedBy = currentUserEmail,
                                    BulkLoad = load,
                                };

                                await unitOfWork.Repository<GoldenRecognition>().AddAsync(recognition);

                                if (approved && draft.Points > 0)
                                {
                                    // El reconocimiento todavía no tiene Id: se enlaza por la entidad y EF pone el recognition_id al guardar.
                                    await GoldenPointsLedger.CreditAsync(unitOfWork, new GoldenPointsCredit(
                                        user.Id,
                                        draft.Points,
                                        GoldenPointsSource.Recognition,
                                        $"Reconocimiento aprobado: {category.Name}",
                                        expires,
                                        currentUserEmail,
                                        Recognition: recognition,
                                        BulkLoad: load));
                                }
                            }

                            result.ProcessedRows = ready.Count;
                            return ResponseDtoHelper.CreateSuccessResponseDto(result);
                        }
                    ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenBulkResultDto>(GoldenRecognitionConstants.UnexpectedError);

                    return WithLoadId(response, load);
                }
                catch (InvalidOperationException ex) when (ex.InnerException is DbUpdateException)
                {
                    // Igual que en puntos: el siguiente intento lee de nuevo.
                }
            }

            return ResponseDtoHelper.CreateErrorResponseDto<GoldenBulkResultDto>(GoldenPointsConstants.ConcurrentChange);
        }

        // ── 3. Aprobar o rechazar pendientes ────────────────────────────

        public async Task<ResponseDto<GoldenBulkResultDto>> ProcessApprovalsAsync(
            GoldenBulkRequestDto<GoldenBulkApprovalRowDto> request, bool dryRun, string currentUserEmail)
        {
            var requestError = ValidateRequest(request.RequestId, request.Rows.Count);
            if (requestError is not null)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenBulkResultDto>(requestError);
            }

            var formatErrors = new List<GoldenBulkRowErrorDto>();
            var drafts = new List<ApprovalDraft>();
            var seenIds = new HashSet<int>();
            var skipped = 0;

            foreach (var row in request.Rows)
            {
                var decision = ParseDecision(row.Decision);
                if (decision == BulkDecision.Skip)
                {
                    skipped++;
                    continue;
                }

                var messages = new List<string>();
                if (row.RecognitionId <= 0)
                {
                    messages.Add(GoldenBulkLoadConstants.RecognitionIdRequired);
                }
                else if (!seenIds.Add(row.RecognitionId))
                {
                    messages.Add(GoldenBulkLoadConstants.DuplicateRecognitionRow);
                }

                if (decision == BulkDecision.Invalid)
                {
                    messages.Add(GoldenBulkLoadConstants.DecisionInvalid);
                }

                var points = row.Points ?? 0;
                if (decision == BulkDecision.Approve && (points < 0 || points > GoldenPointsConstants.MaxPointsPerAssignment))
                {
                    messages.Add(GoldenBulkLoadConstants.ApprovalPointsInvalid);
                }

                var comment = string.IsNullOrWhiteSpace(row.Comment) ? null : row.Comment.Trim();
                if (comment?.Length > GoldenRecognitionApprovalConstants.CommentMaxLength)
                {
                    messages.Add(GoldenBulkLoadConstants.CommentTooLong);
                }

                if (messages.Count > 0)
                {
                    formatErrors.Add(RowError(row.RowNumber, messages));
                }
                else
                {
                    drafts.Add(new ApprovalDraft(row.RowNumber, row.RecognitionId, decision, decision == BulkDecision.Approve ? points : 0, comment));
                }
            }

            if (drafts.Count == 0 && formatErrors.Count == 0)
            {
                return ResponseDtoHelper.CreateErrorResponseDto<GoldenBulkResultDto>(GoldenBulkLoadConstants.NoRows);
            }

            for (var attempt = 1; attempt <= GoldenBulkLoadConstants.SaveAttempts; attempt++)
            {
                try
                {
                    GoldenBulkLoad? load = null;

                    var response = await _transactionHelper.ExecuteWithTransactionAsync<ResponseDto<GoldenBulkResultDto>>(
                        async unitOfWork =>
                        {
                            var previous = await FindLoadAsync(unitOfWork, request.RequestId);
                            if (previous is not null)
                            {
                                return ResponseDtoHelper.CreateSuccessResponseDto(AlreadyProcessed(previous));
                            }

                            // Permisos (pendiente): if (!await CanReviewAsync(currentUserEmail)) throw new UnauthorizedAccessException();

                            // Con seguimiento (se modifican) y con la categoría (para el concepto del abono). includes: elige la sobrecarga.
                            var ids = drafts.Select(draft => draft.RecognitionId).ToList();
                            var recognitions = (await unitOfWork.Repository<GoldenRecognition>().GetListAsync(
                                    r => ids.Contains(r.Id),
                                    includes: q => q.Include(r => r.Category),
                                    disableTracking: false))
                                .ToDictionary(r => r.Id);

                            var errors = new List<GoldenBulkRowErrorDto>(formatErrors);
                            var ready = new List<(ApprovalDraft Draft, GoldenRecognition Recognition)>();

                            foreach (var draft in drafts)
                            {
                                if (!recognitions.TryGetValue(draft.RecognitionId, out var recognition))
                                {
                                    errors.Add(RowError(draft.RowNumber, GoldenBulkLoadConstants.RecognitionNotFound));
                                }
                                else if (recognition.Status != GoldenRecognitionStatus.Pending)
                                {
                                    errors.Add(RowError(draft.RowNumber, GoldenBulkLoadConstants.RecognitionNotPending));
                                }
                                else
                                {
                                    // Permisos (pendiente): nadie aprueba lo que recibió o creó (ValidateReviewerAsync).
                                    ready.Add((draft, recognition));
                                }
                            }

                            var result = Summary(request.Rows.Count, ready.Count, errors, ready.Sum(item => item.Draft.Points), dryRun);
                            result.SkippedRows = skipped;

                            // Validar todo antes de modificar: las entidades tienen seguimiento y el helper guarda igual.
                            if (dryRun || errors.Count > 0)
                            {
                                return ResponseDtoHelper.CreateSuccessResponseDto(result);
                            }

                            load = await AddLoadAsync(unitOfWork, GoldenBulkLoadType.Approvals, request, currentUserEmail);
                            var now = DateTime.UtcNow;
                            var expires = GoldenClock.Today().AddMonths(GoldenPointsConstants.DefaultExpirationMonths);

                            foreach (var (draft, recognition) in ready)
                            {
                                var approve = draft.Decision == BulkDecision.Approve;

                                recognition.Status = approve ? GoldenRecognitionStatus.Approved : GoldenRecognitionStatus.Rejected;
                                recognition.PointsAssigned = approve && draft.Points > 0 ? draft.Points : null;
                                recognition.ReviewedDate = now;
                                recognition.ReviewedBy = currentUserEmail;
                                recognition.ReviewComment = draft.Comment;
                                recognition.UpdatedDate = now;
                                recognition.UpdatedBy = currentUserEmail;

                                if (approve && draft.Points > 0)
                                {
                                    await GoldenPointsLedger.CreditAsync(unitOfWork, new GoldenPointsCredit(
                                        recognition.NomineeUserId,
                                        draft.Points,
                                        GoldenPointsSource.Recognition,
                                        $"Reconocimiento aprobado: {recognition.Category.Name}",
                                        expires,
                                        currentUserEmail,
                                        RecognitionId: recognition.Id,
                                        BulkLoad: load));
                                }
                            }

                            result.ProcessedRows = ready.Count;
                            return ResponseDtoHelper.CreateSuccessResponseDto(result);
                        }
                    ) ?? ResponseDtoHelper.CreateErrorResponseDto<GoldenBulkResultDto>(GoldenRecognitionConstants.UnexpectedError);

                    return WithLoadId(response, load);
                }
                catch (InvalidOperationException ex) when (ex.InnerException is DbUpdateException)
                {
                    // Alguien aprobó uno de estos al mismo tiempo (row_version): el siguiente intento lo marca como "ya fue revisado".
                }
            }

            return ResponseDtoHelper.CreateErrorResponseDto<GoldenBulkResultDto>(GoldenRecognitionApprovalConstants.ConcurrentReview);
        }

        // ── Plantilla "Aprobar pendientes" ──────────────────────────────

        /// <summary>Pendientes, el más antiguo primero, para llenar la plantilla.</summary>
        public async Task<ResponseDto<List<GoldenBulkPendingRowDto>>> GetPendingForTemplateAsync(string currentUserEmail)
        {
            // Permisos (pendiente): if (!await CanReviewAsync(currentUserEmail)) throw new UnauthorizedAccessException();

            return await _transactionHelper.ExecuteQueryAsync<ResponseDto<List<GoldenBulkPendingRowDto>>>(async unitOfWork =>
            {
                // Con selector, el orderBy del genérico se ignora: el orden va dentro del selector.
                var rows = await unitOfWork.Repository<GoldenRecognition>().GetListAsync(
                    r => r.Status == GoldenRecognitionStatus.Pending,
                    selector: q => q
                        .OrderBy(r => r.CreatedDate)
                        .ThenBy(r => r.Id)
                        .Take(GoldenBulkLoadConstants.MaxRows)
                        .Select(r => new GoldenBulkPendingRowDto
                        {
                            RecognitionId = r.Id,
                            NomineeName = r.Nominee.DisplayName,
                            NomineeEmail = r.Nominee.CorportativeEmail,
                            NominatorName = r.Nominator.DisplayName,
                            Category = r.Category.Name,
                            Reason = r.Reason,
                            CreatedAt = r.CreatedDate,
                        }));

                return ResponseDtoHelper.CreateSuccessResponseDto(rows.ToList());
            }) ?? ResponseDtoHelper.CreateErrorResponseDto<List<GoldenBulkPendingRowDto>>(GoldenRecognitionConstants.UnexpectedError);
        }

        // ── Privados ────────────────────────────────────────────────────

        private sealed record PointsDraft(int RowNumber, UserKey Key, int Points, string Concept, DateOnly ExpiresDate);

        private sealed record RecognitionDraft(
            int RowNumber, UserKey Key, string CategoryName, string Reason,
            GoldenRecognitionVisibility Visibility, GoldenRecognitionStatus Status, int Points);

        private enum BulkDecision { Skip, Approve, Reject, Invalid }

        private sealed record ApprovalDraft(int RowNumber, int RecognitionId, BulkDecision Decision, int Points, string? Comment);

        private static string? ValidateRequest(Guid requestId, int rowCount) =>
            requestId == Guid.Empty ? GoldenBulkLoadConstants.RequestIdRequired
            : rowCount == 0 ? GoldenBulkLoadConstants.NoRows
            : rowCount > GoldenBulkLoadConstants.MaxRows ? GoldenBulkLoadConstants.TooManyRows
            : null;

        /// <summary>Vacío o "Pendiente" = pendiente; "Aprobada"/"Aprobado" = aprobado.</summary>
        private static GoldenRecognitionStatus? ParseBulkStatus(string? value) => value?.Trim().ToLowerInvariant() switch
        {
            null or "" or "pendiente" => GoldenRecognitionStatus.Pending,
            "aprobada" or "aprobado" => GoldenRecognitionStatus.Approved,
            _ => null,
        };

        private static BulkDecision ParseDecision(string? value) => value?.Trim().ToLowerInvariant() switch
        {
            null or "" => BulkDecision.Skip,
            "aprobar" or "aprobada" or "aprobado" => BulkDecision.Approve,
            "rechazar" or "rechazada" or "rechazado" => BulkDecision.Reject,
            _ => BulkDecision.Invalid,
        };

        private static GoldenBulkRowErrorDto RowError(int rowNumber, string message) => new() { RowNumber = rowNumber, Message = message };

        private static GoldenBulkRowErrorDto RowError(int rowNumber, IEnumerable<string> messages) => RowError(rowNumber, string.Join(" ", messages));

        private static GoldenBulkResultDto Summary(int totalRows, int validRows, List<GoldenBulkRowErrorDto> errors, int totalPoints, bool dryRun) => new()
        {
            DryRun = dryRun,
            TotalRows = totalRows,
            ValidRows = validRows,
            TotalPoints = totalPoints,
            Errors = errors.OrderBy(error => error.RowNumber).ToList(),
        };

        /// <summary>El mismo requestId ya se aplicó: se informa la carga existente y no se vuelve a aplicar.</summary>
        private static GoldenBulkResultDto AlreadyProcessed(GoldenBulkLoad load) => new()
        {
            AlreadyProcessed = true,
            LoadId = load.Id,
            TotalRows = load.TotalRows,
        };

        private static async Task<GoldenBulkLoad?> FindLoadAsync(IUnitOfWork unitOfWork, Guid requestId) =>
            await unitOfWork.Repository<GoldenBulkLoad>().GetAsync(load => load.RequestId == requestId);

        private static async Task<GoldenBulkLoad> AddLoadAsync<TRow>(
            IUnitOfWork unitOfWork, GoldenBulkLoadType type, GoldenBulkRequestDto<TRow> request, string createdBy)
        {
            var load = new GoldenBulkLoad
            {
                LoadType = type,
                RequestId = request.RequestId,
                FileName = string.IsNullOrWhiteSpace(request.FileName) ? null : request.FileName.Trim()[..Math.Min(request.FileName.Trim().Length, 260)],
                TotalRows = request.Rows.Count,
                CreatedDate = DateTime.UtcNow,
                CreatedBy = createdBy,
            };

            await unitOfWork.Repository<GoldenBulkLoad>().AddAsync(load);
            return load;
        }

        /// <summary>El Id de la carga existe recién después de guardar: se pone en la respuesta al salir del helper.</summary>
        private static ResponseDto<GoldenBulkResultDto> WithLoadId(ResponseDto<GoldenBulkResultDto> response, GoldenBulkLoad? load)
        {
            if (!response.HasError && load is not null && response.Response is not null)
            {
                response.Response.LoadId = load.Id;
            }

            return response;
        }

        private static async Task<User?> FindUserByEmailAsync(IUnitOfWork unitOfWork, string email) =>
            await unitOfWork.Repository<User>().GetAsync(u => u.CorportativeEmail == email);

        /// <summary>Cómo se identifica a una persona en una fila: cédula (solo letras y números) y/o correo (minúsculas).</summary>
        private sealed record UserKey(string? Document, string? Email)
        {
            public bool IsEmpty => Document is null && Email is null;

            public static UserKey From(string? document, string? email)
            {
                var cleanDocument = new string((document ?? string.Empty).Where(char.IsLetterOrDigit).ToArray());
                var cleanEmail = email?.Trim().ToLowerInvariant();
                return new UserKey(cleanDocument.Length > 0 ? cleanDocument : null, string.IsNullOrEmpty(cleanEmail) ? null : cleanEmail);
            }
        }

        /// <summary>Las personas de todas las filas, con una sola consulta.</summary>
        private sealed class UserDirectory
        {
            private readonly Dictionary<string, User> _byDocument;
            private readonly Dictionary<string, User> _byEmail;

            private UserDirectory(IReadOnlyList<User> users)
            {
                _byDocument = users
                    .Where(u => !string.IsNullOrEmpty(u.DocumentNumber)) // ⬅ propiedad real de la cédula en User
                    .GroupBy(u => u.DocumentNumber!)
                    .ToDictionary(g => g.Key, g => g.First());
                _byEmail = users
                    .GroupBy(u => u.CorportativeEmail.ToLowerInvariant())
                    .ToDictionary(g => g.Key, g => g.First());
            }

            public static async Task<UserDirectory> LoadAsync(IUnitOfWork unitOfWork, IEnumerable<UserKey> keys)
            {
                var list = keys.ToList();
                var documents = list.Where(k => k.Document is not null).Select(k => k.Document!).Distinct().ToList();
                var emails = list.Where(k => k.Email is not null).Select(k => k.Email!).Distinct().ToList();

                var users = await unitOfWork.Repository<User>().GetListAsync(u =>
                    documents.Contains(u.DocumentNumber!) || emails.Contains(u.CorportativeEmail)); // ⬅ misma propiedad

                return new UserDirectory(users);
            }

            /// <summary>Cédula primero. Si también viene el correo, deben ser de la misma persona.</summary>
            public (User? User, string? Error) Find(UserKey key)
            {
                User? byDocument = null;
                if (key.Document is not null && !_byDocument.TryGetValue(key.Document, out byDocument))
                {
                    return (null, GoldenBulkLoadConstants.UserNotFound);
                }

                User? byEmail = null;
                if (key.Email is not null && !_byEmail.TryGetValue(key.Email, out byEmail))
                {
                    return (null, GoldenBulkLoadConstants.UserNotFound);
                }

                if (byDocument is not null && byEmail is not null && byDocument.Id != byEmail.Id)
                {
                    return (null, GoldenBulkLoadConstants.IdentifierMismatch);
                }

                return (byDocument ?? byEmail, null);
            }
        }
    }
}
```

> ⚠️ **La cédula en `User`.** El código usa `u.DocumentNumber` (marcado con ⬅). Cámbialo por la propiedad real de `DOCCB.Domain/Entities/User.cs`. Si allí la cédula se guarda con puntos o espacios, la búsqueda no la encuentra: guárdala solo con números, o compara con una columna calculada.
>
> **Resolución de personas.** Es una sola consulta con `IN` para toda la carga, no una por fila.

### `Interfaces/IGoldenBulkLoadService.cs`

```csharp
using DOCCB.Application.Features.Common.Application.DTOs;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;

namespace DOCCB.Application.Features.GoldenPoints.Application.Interfaces
{
    public interface IGoldenBulkLoadService
    {
        Task<ResponseDto<GoldenBulkResultDto>> ProcessPointsAsync(GoldenBulkRequestDto<GoldenBulkPointsRowDto> request, bool dryRun, string currentUserEmail);
        Task<ResponseDto<GoldenBulkResultDto>> ProcessRecognitionsAsync(GoldenBulkRequestDto<GoldenBulkRecognitionRowDto> request, bool dryRun, string currentUserEmail);
        Task<ResponseDto<GoldenBulkResultDto>> ProcessApprovalsAsync(GoldenBulkRequestDto<GoldenBulkApprovalRowDto> request, bool dryRun, string currentUserEmail);
        Task<ResponseDto<List<GoldenBulkPendingRowDto>>> GetPendingForTemplateAsync(string currentUserEmail);
    }
}
```

**Registro** — `ApplicationServiceRegistration.cs` ✏️: `services.AddScoped<IGoldenBulkLoadService, GoldenBulkLoadService>();`

## 2.7 Controlador — `Controllers/GoldenBulkLoadsController.cs`

`ApiResponseConstants.cs` ✏️: `public const string GoldenBulkLoadsErrorMessage = "No se pudo procesar la carga masiva.";`

```csharp
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using DOCCB.Application.Features.GoldenPoints.Application.Dtos;
using DOCCB.Application.Features.GoldenPoints.Application.Interfaces;
using DOCCB.WebApp.Common;
using DOCCB.WebApp.Common.Helper;

namespace DOCCB.WebApp.Controllers
{
    /// <summary>Puntos Dorados: cargas masivas desde Excel (el navegador lee el archivo y envía las filas).</summary>
    [ApiController]
    [Route("api/[controller]")]
    [Authorize]
    // Permisos: pendiente (guía de aprobaciones, sección 9). La validación va en el servicio.
    public class GoldenBulkLoadsController(IGoldenBulkLoadService service) : ControllerBase
    {
        private readonly IGoldenBulkLoadService _service = service;

        /// <summary>Carga de puntos. POST points?dryRun=true revisa sin guardar.</summary>
        [HttpPost("points")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> Points([FromBody] GoldenBulkRequestDto<GoldenBulkPointsRowDto> request, [FromQuery] bool dryRun = false)
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.ProcessPointsAsync(request, dryRun, authenticatedUserInfo.Email);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenBulkLoadsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenBulkLoadsErrorMessage });
            }
        }

        // Recognitions ([HttpPost("recognitions")], ProcessRecognitionsAsync) y
        // Approvals ([HttpPost("approvals")], ProcessApprovalsAsync): la misma acción completa,
        // con su propio try/catch, cambiando el tipo de fila y el método del servicio.

        /// <summary>Pendientes para la plantilla "Aprobar pendientes". GET pending-recognitions</summary>
        [HttpGet("pending-recognitions")]
        [ProducesResponseType(StatusCodes.Status200OK)]
        [ProducesResponseType(StatusCodes.Status400BadRequest)]
        [ProducesResponseType(StatusCodes.Status401Unauthorized)]
        [ProducesResponseType(StatusCodes.Status500InternalServerError)]
        public async Task<IActionResult> PendingRecognitions()
        {
            try
            {
                var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
                if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
                {
                    return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
                }

                var response = await _service.GetPendingForTemplateAsync(authenticatedUserInfo.Email);
                return Ok(response);
            }
            catch (ArgumentException ex)
            {
                return BadRequest(new { message = ApiResponseConstants.GoldenBulkLoadsErrorMessage, error = ex.Message });
            }
            catch (UnauthorizedAccessException)
            {
                return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
            }
            catch (Exception)
            {
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GoldenBulkLoadsErrorMessage });
            }
        }
    }
}
```

> **Las acciones `Recognitions` y `Approvals`** se escriben completas, igual que `Points`, una por una (regla 18: nada de un método privado que comparta el `try/catch`). Aquí se resumen para no repetir 60 líneas.

**Contrato:**

| Método | Ruta | Cuerpo | `response` |
|---|---|---|---|
| `POST` | `/api/GoldenBulkLoads/points?dryRun=true\|false` | `{ requestId, fileName, rows: [{ rowNumber, identification, email, points, concept, expiresDate }] }` | `GoldenBulkResultDto` |
| `POST` | `/api/GoldenBulkLoads/recognitions?dryRun=…` | `{ requestId, fileName, rows: [{ rowNumber, identification, email, category, reason, visibility, status, points }] }` | `GoldenBulkResultDto` |
| `POST` | `/api/GoldenBulkLoads/approvals?dryRun=…` | `{ requestId, fileName, rows: [{ rowNumber, recognitionId, decision, points, comment }] }` | `GoldenBulkResultDto` |
| `GET` | `/api/GoldenBulkLoads/pending-recognitions` | — | `GoldenBulkPendingRowDto[]` |

Los errores de las filas vienen en `response.errors` (con `rowNumber`), con `hasError: false`. `hasError: true` queda para errores del archivo completo (sin filas, más de 1.000, sin `requestId`).

## 2.8 Angular

### `domain/puntos-dorados.ts` ✏️ — agrega

```ts
// ── Cargas masivas ───────────────────────────────────────────────────
export type GoldenBulkKind = 'points' | 'recognitions' | 'approvals';

export interface GoldenBulkPointsRow {
  rowNumber: number;
  identification: string | null;
  email: string | null;
  points: number;
  concept: string;
  /** yyyy-MM-dd o null (12 meses). */
  expiresDate: string | null;
}

export interface GoldenBulkRecognitionRow {
  rowNumber: number;
  identification: string | null;
  email: string | null;
  category: string;
  reason: string;
  visibility: string | null;
  status: string | null;
  points: number | null;
}

export interface GoldenBulkApprovalDecisionRow {
  rowNumber: number;
  recognitionId: number;
  decision: string | null;
  points: number | null;
  comment: string | null;
}

export type GoldenBulkRow = GoldenBulkPointsRow | GoldenBulkRecognitionRow | GoldenBulkApprovalDecisionRow;

export interface GoldenBulkRowError {
  rowNumber: number;
  message: string;
}

export interface GoldenBulkResult {
  dryRun: boolean;
  alreadyProcessed: boolean;
  loadId: number | null;
  totalRows: number;
  validRows: number;
  processedRows: number;
  skippedRows: number;
  totalPoints: number;
  errors: GoldenBulkRowError[];
}

export interface GoldenBulkPendingRow {
  recognitionId: number;
  nomineeName: string;
  nomineeEmail: string;
  nominatorName: string;
  category: string;
  reason: string;
  createdAt: Date;
}
```

Borra `GoldenBulkApprovalRow`, `GoldenBulkApprovalError`, `GoldenBulkApprovalSummary` y `GoldenBulkApprovalResult` cuando el componente de administración deje de usarlos (sección 2.8, "Componente de administración").

### `infrastructure/golden-bulk-loads.service.ts` (nuevo)

```ts
import { HttpClient, HttpErrorResponse, HttpHeaders, HttpParams } from '@angular/common/http';
import { inject, Injectable } from '@angular/core';
import { AuthService } from '@core/services/auth-msal.service';
import { HttpErrorHandlerService } from '@shared/services/http-error-handle.service';
import { environment } from 'enviroments/enviroment';
import { catchError, map, Observable } from 'rxjs';
import { GoldenBulkKind, GoldenBulkPendingRow, GoldenBulkResult, GoldenBulkRow, GoldenResult } from '../domain/puntos-dorados';
import { GoldenResultDto, parseUtc, toResult } from './golden-api';

interface GoldenBulkResultDto extends Omit<GoldenBulkResult, 'loadId'> {
  loadId: number | null;
}

interface GoldenBulkPendingRowDto extends Omit<GoldenBulkPendingRow, 'createdAt'> {
  createdAt: string;
}

/** api/GoldenBulkLoads: revisar y procesar cargas masivas, y los pendientes para la plantilla. */
@Injectable({ providedIn: 'root' })
export class GoldenBulkLoadsService {
  private readonly http = inject(HttpClient);
  private readonly authService = inject(AuthService);
  private readonly errorHandler = inject(HttpErrorHandlerService);
  private readonly apiUrl = `${environment.api.baseUrl}/GoldenBulkLoads`;

  /** dryRun = true: la API revisa y responde los errores sin guardar nada. */
  async process(
    kind: GoldenBulkKind,
    request: { requestId: string; fileName: string; rows: GoldenBulkRow[] },
    dryRun: boolean,
  ): Promise<Observable<GoldenResult<GoldenBulkResult>>> {
    const headers = await this.authHeaders();
    const params = new HttpParams().set('dryRun', dryRun);

    return this.http.post<GoldenResultDto<GoldenBulkResultDto>>(`${this.apiUrl}/${kind}`, request, { headers, params }).pipe(
      map(dto => toResult(dto, result => ({ ...result, errors: result.errors ?? [] }))),
      catchError((error: HttpErrorResponse) => this.errorHandler.handleHttpError(error, 'procesar la carga masiva'))
    );
  }

  async getPendingForTemplate(): Promise<Observable<GoldenResult<GoldenBulkPendingRow[]>>> {
    const headers = await this.authHeaders();

    return this.http.get<GoldenResultDto<GoldenBulkPendingRowDto[]>>(`${this.apiUrl}/pending-recognitions`, { headers }).pipe(
      map(dto => toResult(dto, rows => rows.map(row => ({ ...row, createdAt: parseUtc(row.createdAt) })))),
      catchError((error: HttpErrorResponse) => this.errorHandler.handleHttpError(error, 'obtener los pendientes'))
    );
  }

  private async authHeaders(): Promise<HttpHeaders> {
    const token = await this.authService.getAccessToken(environment.api.apiScopes);
    return new HttpHeaders({ Authorization: `Bearer ${token}` });
  }
}
```

### `application/puntos-dorados.fecade.ts` ✏️

```ts
private readonly bulkLoadsService = inject(GoldenBulkLoadsService);

// ── Cargas masivas (api/GoldenBulkLoads) ─────────────────────────────

reviewBulkLoad(kind: GoldenBulkKind, request: { requestId: string; fileName: string; rows: GoldenBulkRow[] }): Promise<GoldenResult<GoldenBulkResult>> {
  return this.runRecognitionRequest(this.bulkLoadsService.process(kind, request, true), 'No se pudo revisar el archivo.');
}

async processBulkLoad(kind: GoldenBulkKind, request: { requestId: string; fileName: string; rows: GoldenBulkRow[] }): Promise<GoldenResult<GoldenBulkResult>> {
  const result = await this.runRecognitionRequest(
    this.bulkLoadsService.process(kind, request, false),
    'No se pudo procesar la carga. Intenta de nuevo: no se aplicará dos veces.',
  );
  if (!result.hasError && result.response.processedRows > 0) {
    this.notificationService.success(`Carga procesada: ${result.response.processedRows} filas.`, 'toast');
  }
  return result;
}

getPendingForBulkTemplate(): Promise<GoldenResult<GoldenBulkPendingRow[]>> {
  return this.runRecognitionRequest(this.bulkLoadsService.getPendingForTemplate(), 'No se pudieron cargar los pendientes.');
}
```

Borra del facade `processBulkApprovals` y `getMockBulkApprovalRows` (y `GOLDEN_BULK_APPROVAL_MOCK_ROWS` de `mock-data.ts`) cuando el componente de administración deje de usarlos.

### `application/golden-bulk-excel.ts` (nuevo) — plantillas y lectura del archivo

```ts
import * as XLSX from 'xlsx';
import { toIsoDate } from '../infrastructure/golden-api';
import {
  GOLDEN_POINTS_LIMITS,
  GoldenBulkKind,
  GoldenBulkPendingRow,
  GoldenBulkRow,
} from '../domain/puntos-dorados';

interface ColumnSpec {
  /** Encabezado en la plantilla. */
  header: string;
  /** Otros nombres que se aceptan al leer (sin tildes, minúsculas, sin espacios). */
  aliases: string[];
  help: string;
}

export const GOLDEN_BULK_LABELS: Record<GoldenBulkKind, string> = {
  points: 'Cargar puntos',
  recognitions: 'Crear reconocimientos',
  approvals: 'Aprobar pendientes',
};

const COLUMNS: Record<GoldenBulkKind, ColumnSpec[]> = {
  points: [
    { header: 'cedula', aliases: ['cedula', 'identificacion', 'documento'], help: 'Cédula de la persona (o el correo).' },
    { header: 'correo', aliases: ['correo', 'email', 'correoelectronico'], help: 'Correo corporativo (o la cédula). Si van los dos, deben ser de la misma persona.' },
    { header: 'puntos', aliases: ['puntos', 'points', 'cantidad'], help: `Entero de 1 a ${GOLDEN_POINTS_LIMITS.maxPointsPerAssignment.toLocaleString('es-CO')}.` },
    { header: 'concepto', aliases: ['concepto', 'motivo', 'descripcion'], help: 'Lo que la persona ve en su historial (5 a 300 caracteres).' },
    { header: 'vence', aliases: ['vence', 'vencimiento', 'fechavencimiento'], help: 'Opcional. aaaa-mm-dd. Vacío = 12 meses.' },
  ],
  recognitions: [
    { header: 'cedula', aliases: ['cedula', 'identificacion', 'documento'], help: 'Cédula de la persona reconocida (o el correo).' },
    { header: 'correo', aliases: ['correo', 'email', 'correoelectronico'], help: 'Correo corporativo (o la cédula).' },
    { header: 'categoria', aliases: ['categoria', 'category'], help: 'Nombre exacto de una categoría activa.' },
    { header: 'motivo', aliases: ['motivo', 'razon', 'reason'], help: '15 a 1.000 caracteres.' },
    { header: 'visibilidad', aliases: ['visibilidad', 'visibility'], help: 'Opcional: Publica (por defecto) o Privada.' },
    { header: 'estado', aliases: ['estado', 'status'], help: 'Opcional: Pendiente (por defecto) o Aprobada.' },
    { header: 'puntos', aliases: ['puntos', 'points'], help: 'Opcional, solo si el estado es Aprobada. 0 a 100.000.' },
  ],
  approvals: [
    { header: 'id', aliases: ['id', 'reconocimiento', 'idreconocimiento'], help: 'No lo cambies: identifica el reconocimiento.' },
    { header: 'reconocido', aliases: ['reconocido'], help: 'Informativa.' },
    { header: 'correo', aliases: ['correo'], help: 'Informativa.' },
    { header: 'categoria', aliases: ['categoria'], help: 'Informativa.' },
    { header: 'motivo', aliases: ['motivo'], help: 'Informativa.' },
    { header: 'creado', aliases: ['creado'], help: 'Informativa.' },
    { header: 'decision', aliases: ['decision', 'accion'], help: 'Aprobar, Rechazar o vacía (no se toca).' },
    { header: 'puntos', aliases: ['puntos', 'points'], help: 'Solo al aprobar. 0 a 100.000. Vacío = sin puntos.' },
    { header: 'comentario', aliases: ['comentario', 'comment'], help: 'Opcional. Hasta 500 caracteres.' },
  ],
};

const EXAMPLES: Record<Exclude<GoldenBulkKind, 'approvals'>, Record<string, string | number>[]> = {
  points: [{ cedula: '1020304050', correo: '', puntos: 200, concepto: 'Bono por cierre del proyecto', vence: '' }],
  recognitions: [
    { cedula: '1020304050', correo: '', categoria: 'Servicio', motivo: 'Apoyó una contingencia crítica fuera de su horario.', visibilidad: 'Publica', estado: 'Aprobada', puntos: 150 },
  ],
};

/** Descarga la plantilla. "Aprobar pendientes" se llena con los pendientes reales. */
export function downloadBulkTemplate(kind: GoldenBulkKind, pending: GoldenBulkPendingRow[] = []): void {
  const columns = COLUMNS[kind];
  const headers = columns.map(column => column.header);

  const rows: Record<string, string | number>[] =
    kind === 'approvals'
      ? pending.map(item => ({
          id: item.recognitionId,
          reconocido: item.nomineeName,
          correo: item.nomineeEmail,
          categoria: item.category,
          motivo: item.reason,
          creado: toIsoDate(item.createdAt),
          decision: '',
          puntos: '',
          comentario: '',
        }))
      : EXAMPLES[kind];

  const data = XLSX.utils.json_to_sheet(rows, { header: headers });
  data['!cols'] = headers.map(header => ({ wch: header === 'motivo' || header === 'concepto' ? 50 : 18 }));

  const instructions = XLSX.utils.aoa_to_sheet([
    ['Columna', 'Qué va'],
    ...columns.map(column => [column.header, column.help]),
    [],
    ['Máximo', '1.000 filas por archivo.'],
    ['Al subirlo', 'Se revisa primero; si hay errores, no se aplica ninguna fila.'],
  ]);
  instructions['!cols'] = [{ wch: 16 }, { wch: 80 }];

  const workbook = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(workbook, data, 'Datos');
  XLSX.utils.book_append_sheet(workbook, instructions, 'Instrucciones');

  const suffix = { points: 'puntos', recognitions: 'reconocimientos', approvals: 'aprobar-pendientes' }[kind];
  XLSX.writeFile(workbook, `plantilla-${suffix}-${toIsoDate(new Date())}.xlsx`);
}

/** Lee la primera hoja y la convierte en filas para la API. Los encabezados no distinguen tildes ni mayúsculas. */
export async function readBulkFile(kind: GoldenBulkKind, file: File): Promise<GoldenBulkRow[]> {
  const workbook = XLSX.read(await file.arrayBuffer(), { type: 'array', cellDates: true });
  const sheet = workbook.Sheets[workbook.SheetNames[0]];
  if (!sheet) {
    return [];
  }

  const raw = XLSX.utils.sheet_to_json<Record<string, unknown>>(sheet, { defval: '' });

  return raw
    .map((row, index) => ({ row: normalizeKeys(row), rowNumber: index + 2 })) // fila 1 = encabezados
    .filter(({ row }) => Object.values(row).some(value => String(value ?? '').trim() !== ''))
    .map(({ row, rowNumber }) => toRow(kind, row, rowNumber));
}

function toRow(kind: GoldenBulkKind, row: Record<string, unknown>, rowNumber: number): GoldenBulkRow {
  const pick = (header: string) => {
    const spec = COLUMNS[kind].find(column => column.header === header)!;
    const key = spec.aliases.find(alias => alias in row);
    return key ? row[key] : '';
  };

  switch (kind) {
    case 'points':
      return {
        rowNumber,
        identification: text(pick('cedula')),
        email: text(pick('correo')),
        points: toInteger(pick('puntos')) ?? 0,
        concept: text(pick('concepto')) ?? '',
        expiresDate: toDate(pick('vence')),
      };
    case 'recognitions':
      return {
        rowNumber,
        identification: text(pick('cedula')),
        email: text(pick('correo')),
        category: text(pick('categoria')) ?? '',
        reason: text(pick('motivo')) ?? '',
        visibility: text(pick('visibilidad')),
        status: text(pick('estado')),
        points: toInteger(pick('puntos')),
      };
    default:
      return {
        rowNumber,
        recognitionId: toInteger(pick('id')) ?? 0,
        decision: text(pick('decision')),
        points: toInteger(pick('puntos')),
        comment: text(pick('comentario')),
      };
  }
}

function normalizeKeys(row: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(row).map(([key, value]) => [
      key.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/\s+/g, ''),
      value,
    ]),
  );
}

function text(value: unknown): string | null {
  const result = String(value ?? '').trim();
  return result === '' ? null : result;
}

/** Entero o null. "1.500" (miles con punto) también vale. Un número con decimales se envía tal cual y la API lo rechaza. */
function toInteger(value: unknown): number | null {
  if (typeof value === 'number') {
    return Number.isFinite(value) ? value : null;
  }

  const clean = String(value ?? '').trim().replace(/\./g, '');
  return clean === '' || !/^-?\d+$/.test(clean) ? null : Number(clean);
}

/** Celda de fecha (Date, con cellDates) o texto aaaa-mm-dd. Otro formato: null y la API usa 12 meses. */
function toDate(value: unknown): string | null {
  if (value instanceof Date && !Number.isNaN(value.getTime())) {
    return toIsoDate(value);
  }

  const result = String(value ?? '').trim();
  return /^\d{4}-\d{2}-\d{2}$/.test(result) ? result : null;
}
```

> ⚠️ **Fecha en otro formato.** Un `vence` como "07/04/2027" (texto) se lee como vacío y la API aplica 12 meses sin avisar. Si prefieres que dé error, en `toDate` devuelve el texto tal cual y la API lo rechaza al convertirlo. La plantilla lo pide en `aaaa-mm-dd`.

### `presentation/admin/bulk-load/bulk-load.component.ts` (nuevo) — `app-golden-bulk-load`

Un solo componente para las tres cargas:
- **En "Aprobaciones":** crear reconocimientos y aprobar pendientes.
- **En "Puntos":** cargar puntos.

Flujo en tres pasos: **1)** descargar la plantilla, **2)** elegir el archivo (se revisa solo), **3)** procesar.

```ts
import { ChangeDetectionStrategy, Component, computed, inject, input, linkedSignal, output, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { PuntosDoradosFacade } from '../../../application/puntos-dorados.fecade';
import { newRequestId } from '../../../application/golden-request-id';
import { GOLDEN_BULK_LABELS, downloadBulkTemplate, readBulkFile } from '../../../application/golden-bulk-excel';
import { GoldenBulkKind, GoldenBulkResult, GoldenBulkRow } from '../../../domain/puntos-dorados';

const MAX_ROWS = 1_000;

@Component({
  selector: 'app-golden-bulk-load',
  standalone: true,
  imports: [CommonModule],
  templateUrl: './bulk-load.component.html',
  styleUrl: './bulk-load.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class GoldenBulkLoadComponent {
  private readonly facade = inject(PuntosDoradosFacade);

  /** Qué cargas ofrece este lugar. Con más de una se muestra el select "Tipo de carga". */
  readonly kinds = input.required<GoldenBulkKind[]>();
  /** Se procesó una carga: el padre recarga su lista. */
  readonly processed = output<GoldenBulkResult>();

  readonly labels = GOLDEN_BULK_LABELS;
  /** El primer tipo disponible; se puede cambiar con el select. */
  readonly kind = linkedSignal<GoldenBulkKind>(() => this.kinds()[0]);

  readonly fileName = signal('');
  readonly rows = signal<GoldenBulkRow[]>([]);
  readonly review = signal<GoldenBulkResult | null>(null);
  readonly result = signal<GoldenBulkResult | null>(null);
  readonly busy = signal<'template' | 'reading' | 'reviewing' | 'processing' | null>(null);
  readonly errors = signal<string[]>([]);

  /** Uno por archivo: si se reintenta el mismo, la API no lo aplica dos veces. */
  private requestId = '';

  readonly canProcess = computed(() => {
    const review = this.review();
    return !!review && review.errors.length === 0 && review.validRows > 0 && !this.busy() && !this.result();
  });

  setKind(value: string): void {
    const kind = this.kinds().find(option => option === value);
    if (kind && kind !== this.kind()) {
      this.kind.set(kind);
      this.reset();
    }
  }

  async downloadTemplate(): Promise<void> {
    if (this.kind() !== 'approvals') {
      downloadBulkTemplate(this.kind());
      return;
    }

    // "Aprobar pendientes" se descarga con los pendientes reales.
    this.busy.set('template');
    try {
      const pending = await this.facade.getPendingForBulkTemplate();
      if (pending.hasError) {
        this.errors.set(pending.errors);
        return;
      }

      if (pending.response.length === 0) {
        this.errors.set(['No hay reconocimientos pendientes para aprobar.']);
        return;
      }

      downloadBulkTemplate('approvals', pending.response);
    } finally {
      this.busy.set(null);
    }
  }

  async onFileSelected(event: Event): Promise<void> {
    const input = event.target as HTMLInputElement;
    const file = input.files?.[0];
    input.value = ''; // permite volver a elegir el mismo archivo después de corregirlo
    this.reset();

    if (!file) {
      return;
    }

    if (!/\.(xlsx|xls)$/i.test(file.name)) {
      this.errors.set(['Formato no válido. Carga un archivo .xlsx o .xls.']);
      return;
    }

    this.fileName.set(file.name);
    this.busy.set('reading');

    try {
      const rows = await readBulkFile(this.kind(), file);
      if (rows.length === 0) {
        this.errors.set(['El archivo no tiene filas para procesar.']);
        return;
      }

      if (rows.length > MAX_ROWS) {
        this.errors.set([`El archivo tiene ${rows.length} filas; el máximo es ${MAX_ROWS}. Divídelo en varios.`]);
        return;
      }

      this.rows.set(rows);
      this.requestId = newRequestId();

      // Revisión automática: la API valida todo sin guardar.
      this.busy.set('reviewing');
      const review = await this.facade.reviewBulkLoad(this.kind(), this.request());
      if (review.hasError) {
        this.errors.set(review.errors);
        return;
      }

      this.review.set(review.response);
    } catch {
      this.errors.set(['No fue posible leer el archivo. Revisa que sea la plantilla y que no esté protegido.']);
    } finally {
      this.busy.set(null);
    }
  }

  async process(): Promise<void> {
    if (!this.canProcess()) {
      return;
    }

    this.busy.set('processing');

    try {
      const result = await this.facade.processBulkLoad(this.kind(), this.request());
      if (result.hasError) {
        this.errors.set(result.errors);
        return;
      }

      // Doble clic o reintento: la API ya lo había aplicado. Se muestra la carga existente.
      if (result.response.alreadyProcessed) {
        this.result.set(result.response);
        return;
      }

      // Si algo cambió entre la revisión y el clic, la API devuelve errores y no aplica nada.
      if (result.response.errors.length > 0) {
        this.review.set(result.response);
        return;
      }

      this.result.set(result.response);
      this.processed.emit(result.response);
    } finally {
      this.busy.set(null);
    }
  }

  reset(): void {
    this.fileName.set('');
    this.rows.set([]);
    this.review.set(null);
    this.result.set(null);
    this.errors.set([]);
  }

  private request(): { requestId: string; fileName: string; rows: GoldenBulkRow[] } {
    return { requestId: this.requestId, fileName: this.fileName(), rows: this.rows() };
  }
}
```

### `bulk-load.component.html`

```html
<section class="bulk-approval-box gb" aria-labelledby="gb-title">
  <div class="bulk-approval-header">
    <h3 id="gb-title"><i class="fa-solid fa-file-excel" aria-hidden="true"></i> Carga masiva XLSX</h3>
    <p>Descarga la plantilla, llénala y súbela. Se revisa antes de aplicar: si hay errores, no se aplica ninguna fila.</p>
  </div>

  @if (kinds().length > 1) {
    <div class="filter-field gb-kind">
      <label class="field-label" for="gb-kind">Tipo de carga</label>
      <select id="gb-kind" class="field-input" [disabled]="!!busy()" (change)="setKind($any($event.target).value)">
        @for (option of kinds(); track option) {
          <option [value]="option" [selected]="kind() === option">{{ labels[option] }}</option>
        }
      </select>
    </div>
  }

  <ol class="gb-steps">
    <li>
      <span class="gb-step">1</span>
      <button type="button" class="btn-secondary" [disabled]="!!busy()" (click)="downloadTemplate()">
        <i class="fa-solid fa-download" aria-hidden="true"></i>
        {{ busy() === 'template' ? 'Preparando…' : 'Descargar plantilla' }}
      </button>
    </li>
    <li>
      <span class="gb-step">2</span>
      <label class="bulk-file-label" [class.is-disabled]="!!busy()">
        <input type="file" class="bulk-file-input" accept=".xlsx,.xls" [disabled]="!!busy()" (change)="onFileSelected($event)" />
        <span class="label-content">
          <i class="fa-solid fa-paperclip" aria-hidden="true"></i>
          {{ fileName() || 'Seleccionar archivo' }}
        </span>
      </label>
    </li>
    <li>
      <span class="gb-step">3</span>
      <button type="button" class="btn-bulk-process" [disabled]="!canProcess()" (click)="process()">
        {{ busy() === 'processing' ? 'Procesando…' : 'Procesar' }}
      </button>
    </li>
  </ol>

  @if (busy() === 'reading' || busy() === 'reviewing') {
    <p class="gb-status" role="status">{{ busy() === 'reading' ? 'Leyendo el archivo…' : 'Revisando las filas…' }}</p>
  }

  @for (error of errors(); track error) {
    <p class="gb-error" role="alert">{{ error }}</p>
  }

  <!-- Revisión -->
  @if (review(); as current) {
    <div class="bulk-summary" aria-live="polite">
      <strong>Revisión:</strong>
      <span>{{ current.totalRows }} filas</span>
      <span>Correctas: {{ current.validRows }}</span>
      @if (current.skippedRows) {
        <span>Sin decisión (no se tocan): {{ current.skippedRows }}</span>
      }
      <span [class.gb-bad]="current.errors.length">Con error: {{ current.errors.length }}</span>
      @if (current.totalPoints) {
        <span>Puntos: {{ current.totalPoints | number }}</span>
      }
    </div>

    @if (current.errors.length) {
      <div class="table-wrap gb-errors">
        <table class="table">
          <thead>
            <tr><th>Fila</th><th>Error</th></tr>
          </thead>
          <tbody>
            @for (error of current.errors; track error.rowNumber + error.message) {
              <tr>
                <td>{{ error.rowNumber || '—' }}</td>
                <td>{{ error.message }}</td>
              </tr>
            }
          </tbody>
        </table>
      </div>
      <p class="gb-hint">Corrige el archivo y vuelve a seleccionarlo. No se aplicó nada.</p>
    } @else if (!result()) {
      <p class="gb-hint gb-ok"><i class="fa-solid fa-circle-check" aria-hidden="true"></i> Todo correcto. Presiona "Procesar" para aplicar.</p>
    }
  }

  <!-- Resultado -->
  @if (result(); as done) {
    <div class="bulk-summary gb-done" role="status">
      <strong>{{ done.alreadyProcessed ? 'Este archivo ya se había procesado.' : 'Carga procesada.' }}</strong>
      <span>Carga #{{ done.loadId }}</span>
      <span>Filas aplicadas: {{ done.processedRows }}</span>
      @if (done.totalPoints) {
        <span>Puntos: {{ done.totalPoints | number }}</span>
      }
      <button type="button" class="btn-secondary" (click)="reset()">Cargar otro archivo</button>
    </div>
  }
</section>
```

### `bulk-load.component.scss`

```scss
@use '../../shared/puntos-dorados-shared.scss' as *;

:host {
  display: block;
}

.gb-kind {
  max-width: 20rem;
  margin-bottom: 1rem;
}

.gb-steps {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(14rem, 1fr));
  gap: 0.75rem;
  margin: 0 0 1rem;
  padding: 0;
  list-style: none;

  li {
    display: flex;
    align-items: center;
    gap: 0.6rem;
  }

  .btn-secondary,
  .btn-bulk-process,
  .bulk-file-label {
    flex: 1;
  }
}

.gb-step {
  display: inline-grid;
  flex-shrink: 0;
  place-items: center;
  width: 1.75rem;
  height: 1.75rem;
  border-radius: 50%;
  background: var(--bs-warning);
  color: var(--bs-dark);
  font-size: 0.8rem;
  font-weight: 800;
}

.bulk-file-label.is-disabled {
  opacity: 0.6;
  pointer-events: none;
}

.gb-status,
.gb-hint {
  margin: 0.5rem 0;
  color: var(--bs-secondary-color);
  font-size: 0.875rem;
}

.gb-ok {
  color: var(--bs-success);
  font-weight: 600;
}

.gb-error {
  margin: 0.5rem 0;
  color: var(--bs-danger);
  font-size: 0.875rem;
}

.gb-bad {
  color: var(--bs-danger);
  font-weight: 700;
}

.gb-errors {
  max-height: 16rem;
  overflow-y: auto;
}
```

> Usa las clases que ya tiene la carga masiva de hoy (`.bulk-approval-box`, `.bulk-file-label`, `.btn-bulk-process`, `.bulk-summary`, `.table-wrap`) desde `puntos-dorados-shared.scss`. Si esas clases están en el SCSS del componente de administración y no en el compartido, muévelas al compartido.

### Componente de administración ✏️

**Aprobaciones.** En `puntos-dorados-admin.component.html` reemplaza **todo** el bloque de carga masiva actual (`.bulk-approval-box`, los `bulk-summary` de errores, filas y resultado, y la tabla de filas) por:

```html
<app-golden-bulk-load [kinds]="['recognitions', 'approvals']" (processed)="reloadApprovals()" />
```

En `puntos-dorados-admin.component.ts`:
- **Agrega** `GoldenBulkLoadComponent` a `imports`.
- **Borra:**
  - las señales `bulkApprovalResult`, `bulkApprovalRows`, `bulkUploadErrors` y `selectedBulkFileName`;
  - los métodos `onBulkFileSelected`, `processUploadedBulkApproval`, `parseBulkApprovalXlsx`, `normalizeRowKeys`, `getNormalizedValue` y `trackByBulkRow`;
  - los imports de `GoldenBulkApprovalRow` y `GoldenBulkApprovalResult`, y el de `XLSX` si ya no se usa ahí.

**Puntos.** En `points-admin/points-admin.component.html`, debajo de la tarjeta "Asignar puntos":

```html
<app-golden-bulk-load [kinds]="['points']" (processed)="history.reload()" />
```

Agrega `GoldenBulkLoadComponent` a los `imports` de `GoldenPointsAdminComponent`.

---

# Parte 3 — Dashboard ampliado

## 3.1 Qué se agrega

| Pedido | Cómo queda |
|---|---|
| Número de **usuarios reconocidos** | Indicador nuevo: personas **distintas** con reconocimientos **aprobados** en el período (por fecha de aprobación), con su % contra el período anterior. |
| Aprobaciones, puntos asignados, redenciones | Ya están. |
| Cuántos reconocimientos en los filtros | Ya está ("Reconocimientos del período"). |
| **El estado de cada reconocimiento** | Tabla nueva **"Reconocimientos del período"** (fecha, reconocido, quién reconoce, categoría, estado, puntos), paginada con "Cargar más" y con los mismos filtros. |
| Reconocimientos por categoría | Ya está. |
| **Puntos asignados por fecha** | La gráfica pasa a ser **por día** si el período es de hasta 62 días, y **por mes** si es más largo. Cubre exactamente el período filtrado. |
| Filtros: colaboradores, fechas, estado, categoría | Los mismos del modal (`FilterState`). Ahora también filtran la tabla. |

> **"Usuarios reconocidos" cuenta aprobados.** Un pendiente todavía no es un reconocimiento otorgado. Con el filtro de estado en "Pendiente" da 0, igual que "Aprobaciones".

## 3.2 API ✏️ (sobre la [guía del dashboard](puntos-dorados-dashboard-api.md))

### `IGoldenDashboardQueryRepository.cs` ✏️ — agrega

```csharp
public sealed record GoldenDayPoints(DateTime Day, GoldenPointsSource Source, int Points);

public sealed record GoldenDashboardRecognitionRow(
    int Id,
    string NomineeName,
    string NomineeEmail,
    string NominatorName,
    string CategoryName,
    string CategoryIcon,
    string CategoryColor,
    GoldenRecognitionStatus Status,
    int? PointsAssigned,
    DateTime CreatedDate,
    DateTime? ReviewedDate);
```

```csharp
/// <summary>Personas distintas con reconocimientos aprobados en el rango (por fecha de aprobación).</summary>
Task<int> CountRecognizedUsersAsync(GoldenDashboardScope scope, DateTime fromUtc, DateTime toUtc);

/// <summary>Puntos asignados por día (hora de Colombia) y origen.</summary>
Task<IReadOnlyList<GoldenDayPoints>> SumPointsByDayAsync(GoldenDashboardScope scope, DateTime fromUtc, DateTime toUtc);

/// <summary>Reconocimientos creados en el rango, con los filtros, del más nuevo al más viejo.</summary>
Task<(IReadOnlyList<GoldenDashboardRecognitionRow> Rows, int TotalCount)> GetRecognitionsPageAsync(
    GoldenDashboardScope scope, DateTime fromUtc, DateTime toUtc, int page, int pageSize);
```

### `GoldenDashboardQueryRepository.cs` ✏️ — agrega

```csharp
public Task<int> CountRecognizedUsersAsync(GoldenDashboardScope scope, DateTime fromUtc, DateTime toUtc) =>
    Recognitions(scope)
        .Where(r => r.Status == GoldenRecognitionStatus.Approved && r.ReviewedDate >= fromUtc && r.ReviewedDate < toUtc)
        .Select(r => r.NomineeUserId)
        .Distinct()
        .CountAsync();

public async Task<IReadOnlyList<GoldenDayPoints>> SumPointsByDayAsync(GoldenDashboardScope scope, DateTime fromUtc, DateTime toUtc) =>
    await AssignedPoints(scope, fromUtc, toUtc)
        .Select(t => new { Day = t.CreatedDate.AddHours(GoldenClock.UtcOffsetHours).Date, t.Source, t.Points })
        .GroupBy(x => new { x.Day, x.Source })
        .Select(g => new GoldenDayPoints(g.Key.Day, g.Key.Source, g.Sum(x => x.Points)))
        .ToListAsync();

public async Task<(IReadOnlyList<GoldenDashboardRecognitionRow> Rows, int TotalCount)> GetRecognitionsPageAsync(
    GoldenDashboardScope scope, DateTime fromUtc, DateTime toUtc, int page, int pageSize)
{
    var query = Recognitions(scope)
        .Where(r => r.CreatedDate >= fromUtc && r.CreatedDate < toUtc)
        .OrderByDescending(r => r.CreatedDate)
        .ThenByDescending(r => r.Id);

    var total = await query.CountAsync();

    var rows = await query
        .Skip((page - 1) * pageSize)
        .Take(pageSize)
        .Select(r => new GoldenDashboardRecognitionRow(
            r.Id,
            r.Nominee.DisplayName,
            r.Nominee.CorportativeEmail,
            r.Nominator.DisplayName,
            r.Category.Name,
            r.Category.Icon,
            r.Category.Color,
            r.Status,
            r.PointsAssigned,
            r.CreatedDate,
            r.ReviewedDate))
        .ToListAsync();

    return (rows, total);
}
```

### `GoldenDashboardDtos.cs` ✏️

```csharp
// En GoldenDashboardKpisDto:
public GoldenDashboardKpiDto RecognizedUsers { get; set; } = new();

// En GoldenDashboardDto:
/// <summary>day | month: cómo vienen agrupados PointsByDate.</summary>
public string PointsGranularity { get; set; } = "month";
/// <summary>Puntos del período filtrado, por día o por mes, también los vacíos en 0.</summary>
public List<GoldenDashboardDatePointsDto> PointsByDate { get; set; } = [];

public class GoldenDashboardDatePointsDto
{
    /// <summary>El día, o el primer día del mes.</summary>
    public DateOnly Date { get; set; }
    public int RecognitionPoints { get; set; }
    public int ManualPoints { get; set; }
    public int Total { get; set; }
}

/// <summary>Filtros del dashboard + página, para la tabla.</summary>
public class GoldenDashboardRecognitionsQueryDto : GoldenDashboardQueryDto
{
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 10;
}

public class GoldenDashboardRecognitionDto
{
    public int Id { get; set; }
    public string NomineeName { get; set; } = string.Empty;
    public string NomineeEmail { get; set; } = string.Empty;
    public string NominatorName { get; set; } = string.Empty;
    public string CategoryName { get; set; } = string.Empty;
    public string CategoryIcon { get; set; } = string.Empty;
    public string CategoryColor { get; set; } = string.Empty;
    /// <summary>Pendiente | Aprobada | Rechazada</summary>
    public string Status { get; set; } = string.Empty;
    public int? PointsAssigned { get; set; }
    public DateTime CreatedAt { get; set; }
    public DateTime? ReviewedAt { get; set; }
}
```

### `GoldenDashboardConstants.cs` ✏️ — agrega

```csharp
/// <summary>Hasta este número de días, los puntos se agrupan por día; más, por mes.</summary>
public const int DailyPointsMaxDays = 62;
```

### `GoldenDashboardService.GetAsync` ✏️

Agrega a las consultas:

```csharp
var recognizedUsers = await _queryRepository.CountRecognizedUsersAsync(scope, fromUtc, toUtc);
var previousRecognizedUsers = await _queryRepository.CountRecognizedUsersAsync(scope, previousFromUtc, previousToUtc);

// Puntos del período filtrado: por día si es corto, por mes si es largo.
var days = filter.To.DayNumber - filter.From.DayNumber + 1;
var daily = days <= GoldenDashboardConstants.DailyPointsMaxDays;
var periodPoints = daily
    ? (await _queryRepository.SumPointsByDayAsync(scope, fromUtc, toUtc))
        .Select(x => (Date: DateOnly.FromDateTime(x.Day), x.Source, x.Points))
        .ToList()
    : (await _queryRepository.SumPointsByMonthAsync(scope, fromUtc, toUtc))
        .Select(x => (Date: new DateOnly(x.Year, x.Month, 1), x.Source, x.Points))
        .ToList();

var buckets = daily
    ? Enumerable.Range(0, days).Select(offset => filter.From.AddDays(offset)).ToList()
    : GoldenDashboardValidator.Months(filter.From, filter.To);
```

Y en el `GoldenDashboardDto` que se arma:

```csharp
// En Kpis:
RecognizedUsers = Kpi(recognizedUsers, previousRecognizedUsers),

PointsGranularity = daily ? "day" : "month",
PointsByDate = buckets.Select(date =>
{
    var inBucket = periodPoints.Where(x => x.Date == date).ToList();
    var recognition = inBucket.Where(x => x.Source == GoldenPointsSource.Recognition).Sum(x => x.Points);
    var manual = inBucket.Where(x => x.Source == GoldenPointsSource.Manual).Sum(x => x.Points);
    return new GoldenDashboardDatePointsDto { Date = date, RecognitionPoints = recognition, ManualPoints = manual, Total = recognition + manual };
}).ToList(),
```

> `PointsByMonth` (de la tendencia de 6 meses) se queda: no se rompe nada que ya lo use.

### `GoldenDashboardService.GetRecognitionsAsync` ✏️ — agrega (y en la interfaz)

```csharp
public async Task<ResponseDto<GoldenPagedResultDto<GoldenDashboardRecognitionDto>>> GetRecognitionsAsync(GoldenDashboardRecognitionsQueryDto query, string currentUserEmail)
{
    var errors = new List<string>();
    var filter = GoldenDashboardValidator.Normalize(query, GoldenClock.Today(), errors);

    if (errors.Count > 0)
    {
        return ResponseDtoHelper.CreateErrorResponseDto<GoldenPagedResultDto<GoldenDashboardRecognitionDto>>(errors);
    }

    // Permisos (pendiente): igual que GetAsync.

    var page = Math.Max(1, query.Page);
    var pageSize = Math.Clamp(query.PageSize, 1, GoldenRecognitionConstants.MaxPageSize);
    var scope = await ScopeAsync(filter); // el helper de la guía de exportar; si no lo tienes, las 4 líneas de GetAsync

    var (rows, total) = await _queryRepository.GetRecognitionsPageAsync(
        scope,
        GoldenClock.StartOfDayUtc(filter.From),
        GoldenClock.StartOfDayUtc(filter.To.AddDays(1)),
        page,
        pageSize);

    return ResponseDtoHelper.CreateSuccessResponseDto(new GoldenPagedResultDto<GoldenDashboardRecognitionDto>
    {
        Items = rows.Select(row => new GoldenDashboardRecognitionDto
        {
            Id = row.Id,
            NomineeName = row.NomineeName,
            NomineeEmail = row.NomineeEmail,
            NominatorName = row.NominatorName,
            CategoryName = row.CategoryName,
            CategoryIcon = row.CategoryIcon,
            CategoryColor = row.CategoryColor,
            Status = GoldenRecognitionCodes.ToStatusCode(row.Status),
            PointsAssigned = row.PointsAssigned,
            CreatedAt = row.CreatedDate,
            ReviewedAt = row.ReviewedDate,
        }).ToList(),
        Page = page,
        PageSize = pageSize,
        TotalCount = total,
    });
}
```

### `GoldenDashboardController.cs` ✏️ — agrega la acción

`[HttpGet("recognitions")]` con `[FromQuery] GoldenDashboardRecognitionsQueryDto query`, que llama `_service.GetRecognitionsAsync(query, email)`. Es el mismo `try/catch` completo de `Get`.

```text
GET /api/GoldenDashboard/recognitions?from=…&to=…&userEmails=…&statuses=…&categoryIds=…&page=1&pageSize=10
```

## 3.3 Angular ✏️

### `domain/puntos-dorados.ts`

```ts
// En GoldenDashboard.kpis agrega:
//   recognizedUsers: GoldenDashboardKpiValue;
// Y en GoldenDashboard:
//   pointsGranularity: 'day' | 'month';
//   pointsByDate: { date: Date; recognitionPoints: number; manualPoints: number; total: number }[];

export interface GoldenDashboardRecognitionRow {
  id: number;
  nomineeName: string;
  nomineeEmail: string;
  nominatorName: string;
  categoryName: string;
  categoryIcon: string;
  categoryColor: string;
  status: GoldenNominationStatus;
  pointsAssigned: number | null;
  createdAt: Date;
  reviewedAt: Date | null;
}
```

### `infrastructure/golden-dashboard.mapper.ts`

```ts
// En GoldenDashboardDto:
//   kpis.recognizedUsers: GoldenDashboardKpiDto;
//   pointsGranularity: string;
//   pointsByDate: { date: string; recognitionPoints: number; manualPoints: number; total: number }[];

// En toDashboard:
//   kpis.recognizedUsers: toKpi(dto.kpis.recognizedUsers),
//   pointsGranularity: dto.pointsGranularity === 'day' ? 'day' : 'month',
//   pointsByDate: (dto.pointsByDate ?? []).map(point => ({ ...point, date: parseDateOnly(point.date) })),

export interface GoldenDashboardRecognitionDto {
  id: number;
  nomineeName: string;
  nomineeEmail: string;
  nominatorName: string;
  categoryName: string;
  categoryIcon: string;
  categoryColor: string;
  status: string;
  pointsAssigned: number | null;
  createdAt: string;
  reviewedAt: string | null;
}

export function toDashboardRecognition(dto: GoldenDashboardRecognitionDto): GoldenDashboardRecognitionRow {
  return {
    ...dto,
    status: toStatus(dto.status),
    createdAt: parseUtc(dto.createdAt),
    reviewedAt: dto.reviewedAt ? parseUtc(dto.reviewedAt) : null,
  };
}
```

(Agrega `parseUtc` al import de `./golden-api` y `GoldenDashboardRecognitionRow` al del dominio.)

### `infrastructure/golden-dashboard.service.ts` — agrega

```ts
async getRecognitions(filters: GoldenDashboardFilters, page: number, pageSize: number): Promise<Observable<GoldenResult<GoldenPagedResult<GoldenDashboardRecognitionRow>>>> {
  const headers = await this.authHeaders();
  const params = this.params(filters).set('page', page).set('pageSize', pageSize);

  return this.http
    .get<GoldenResultDto<GoldenPagedResultDto<GoldenDashboardRecognitionDto>>>(`${this.baseUrl}/recognitions`, { headers, params })
    .pipe(
      map(dto => toResult(dto, pageDto => toPage(pageDto, toDashboardRecognition))),
      catchError(error => this.handleError(error)),
    );
}
```

### `application/puntos-dorados.fecade.ts` — agrega

```ts
getDashboardRecognitions(filters: GoldenDashboardFilters, page: number, pageSize: number): Promise<GoldenResult<GoldenPagedResult<GoldenDashboardRecognitionRow>>> {
  return this.runRecognitionRequest(this.dashboardService.getRecognitions(filters, page, pageSize), 'No se pudieron cargar los reconocimientos del período.');
}
```

### `presentation/admin/golden-dashboard-charts.ts` — puntos por fecha

Reemplaza `pointsChartConfig` para que use `pointsByDate` y etiquete por día o por mes:

```ts
const DAY = new Intl.DateTimeFormat('es-CO', { day: 'numeric', month: 'short' });

export function pointsChartConfig(data: GoldenDashboard): ChartConfiguration<'bar'> {
  const points = data.pointsByDate;
  const label = (date: Date) => (data.pointsGranularity === 'day' ? DAY.format(date) : monthLabel(date));

  return {
    type: 'bar',
    data: {
      labels: points.map(point => label(point.date)),
      datasets: [
        { label: 'Reconocimientos', data: points.map(point => point.recognitionPoints), backgroundColor: DASHBOARD_COLORS.black, borderRadius: 8, stack: 'points' },
        { label: 'Asignaciones', data: points.map(point => point.manualPoints), backgroundColor: DASHBOARD_COLORS.yellow, borderRadius: 8, stack: 'points' },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: { legend: LEGEND_DEFAULTS, tooltip: TOOLTIP_DEFAULTS },
      scales: { x: { stacked: true }, y: { stacked: true, beginAtZero: true } },
    },
  };
}
```

### `golden-dashboard.component.ts`

```ts
import { PagedList } from '../../../application/paged-list';
import { GoldenDashboardRecognitionRow } from '../../../domain/puntos-dorados';

/** Tabla "Reconocimientos del período": mismos filtros que las tarjetas y las gráficas. */
readonly recognitionsTable = new PagedList<GoldenDashboardRecognitionRow>(
  (page, pageSize) => this.facade.getDashboardRecognitions(this.toApiDashboardFilters(this.dashboardFilters()), page, pageSize),
  row => row.id,
  10,
);
```

En `dashboardKpis`, agrega la tarjeta nueva (segunda):

```ts
return [
  { label: hasRange ? 'Reconocimientos del período' : 'Reconocimientos del mes', kpi: data.kpis.recognitions },
  { label: 'Usuarios reconocidos', kpi: data.kpis.recognizedUsers },
  { label: 'Aprobaciones', kpi: data.kpis.approvals },
  { label: 'Puntos asignados', kpi: data.kpis.pointsAssigned },
  { label: 'Redenciones', kpi: data.kpis.redemptions },
].map(…); // igual que hoy
```

La tabla se recarga junto con el dashboard. En `loadDashboard()`, después de `const request = ++this.dashboardRequestId;`:

```ts
void this.recognitionsTable.reload();
```

> `toApiDashboardFilters` usa `this.categories()`. `openDashboard()` carga las categorías **antes** de `loadDashboard()`, así que el filtro por categoría ya funciona en la tabla desde la primera carga.

### `golden-dashboard.component.html`

El subtítulo de la gráfica de puntos:

```html
<header>
  <h3>Puntos asignados</h3>
  <p>{{ dashboardData()?.pointsGranularity === 'day' ? 'Por día' : 'Por mes' }} · reconocimientos y asignaciones</p>
</header>
```

Y la tabla, después de `.dashboard-charts`:

```html
<section class="dashboard-table-card" aria-labelledby="dashboard-table-title">
  <header class="dashboard-table-card__head">
    <div>
      <h3 id="dashboard-table-title">Reconocimientos del período</h3>
      <p>El estado de cada reconocimiento, con los filtros aplicados.</p>
    </div>
    @if (recognitionsTable.loaded()) {
      <span class="dashboard-table-card__count">{{ recognitionsTable.totalCount() | number }}</span>
    }
  </header>

  <div class="dashboard-table-wrap" [class.is-loading]="recognitionsTable.loading() && recognitionsTable.loaded()">
    <table class="dashboard-table">
      <thead>
        <tr>
          <th scope="col">Fecha</th>
          <th scope="col">Reconocido</th>
          <th scope="col">Reconocido por</th>
          <th scope="col">Categoría</th>
          <th scope="col">Estado</th>
          <th scope="col" class="text-end">Puntos</th>
        </tr>
      </thead>
      <tbody>
        @for (row of recognitionsTable.items(); track row.id) {
          <tr>
            <td data-label="Fecha">{{ row.createdAt | date: 'dd/MM/yyyy' }}</td>
            <td data-label="Reconocido">
              <strong>{{ row.nomineeName }}</strong>
              <small>{{ row.nomineeEmail }}</small>
            </td>
            <td data-label="Reconocido por">{{ row.nominatorName }}</td>
            <td data-label="Categoría">
              <i [class]="row.categoryIcon || 'fa-solid fa-medal'" [style.color]="row.categoryColor" aria-hidden="true"></i>
              {{ row.categoryName }}
            </td>
            <td data-label="Estado">
              <span class="dashboard-status" [attr.data-status]="row.status">{{ row.status }}</span>
            </td>
            <td data-label="Puntos" class="text-end">{{ row.pointsAssigned ? (row.pointsAssigned | number) : '—' }}</td>
          </tr>
        }
      </tbody>
    </table>

    @if (recognitionsTable.isFirstLoad()) {
      <p class="dashboard-table-empty">Cargando reconocimientos…</p>
    }

    @if (recognitionsTable.isEmpty()) {
      <p class="dashboard-table-empty">No hay reconocimientos con estos filtros.</p>
    }
  </div>

  @if (recognitionsTable.error()) {
    <div class="dashboard-error" role="alert">
      <span>{{ recognitionsTable.error() }}</span>
      <button type="button" class="btn-secondary" (click)="recognitionsTable.reload()">Reintentar</button>
    </div>
  }

  @if (recognitionsTable.hasMore()) {
    <button type="button" class="btn-secondary dashboard-table-more" [disabled]="recognitionsTable.loading()" (click)="recognitionsTable.loadMore()">
      {{ recognitionsTable.loading() ? 'Cargando…' : 'Cargar más' }}
    </button>
  }
</section>
```

### `golden-dashboard.component.scss` — agrega

```scss
.dashboard-table-card {
  margin-top: 1.25rem;
  padding: 1.25rem 1.5rem;
  border: 1px solid var(--bs-border-color-translucent);
  border-radius: 1rem;
  background: var(--bs-body-bg);
}

.dashboard-table-card__head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 1rem;
  margin-bottom: 1rem;

  h3 {
    margin: 0;
    font-size: 1.1rem;
    font-weight: 700;
  }

  p {
    margin: 0.15rem 0 0;
    color: var(--bs-secondary-color);
    font-size: 0.85rem;
  }
}

.dashboard-table-card__count {
  padding: 0.2rem 0.75rem;
  border-radius: 999px;
  background: color-mix(in srgb, var(--bs-warning) 18%, transparent);
  font-weight: 700;
}

.dashboard-table-wrap {
  overflow-x: auto;
  border: 1px solid var(--bs-border-color-translucent);
  border-radius: 0.75rem;
  transition: opacity 0.2s ease;

  &.is-loading {
    opacity: 0.55;
  }
}

.dashboard-table {
  width: 100%;
  font-size: 0.875rem;

  th {
    padding: 0.7rem 0.9rem;
    background: var(--bs-warning);
    color: var(--bs-dark);
    font-size: 0.72rem;
    font-weight: 700;
    letter-spacing: 0.05em;
    text-transform: uppercase;
    white-space: nowrap;
  }

  td {
    padding: 0.6rem 0.9rem;
    border-top: 1px solid var(--bs-border-color-translucent);
    vertical-align: middle;
  }

  small {
    display: block;
    color: var(--bs-secondary-color);
  }
}

.dashboard-status {
  --tone: var(--bs-warning);

  padding: 0.15rem 0.6rem;
  border: 1px solid color-mix(in srgb, var(--tone) 55%, transparent);
  border-radius: 999px;
  background: color-mix(in srgb, var(--tone) 12%, transparent);
  font-size: 0.75rem;
  font-weight: 700;

  &[data-status='Aprobada'] { --tone: var(--bs-success); }
  &[data-status='Rechazada'] { --tone: var(--bs-danger); }
}

.dashboard-table-empty {
  padding: 1.5rem;
  color: var(--bs-secondary-color);
  text-align: center;
}

.dashboard-table-more {
  display: block;
  margin: 1rem auto 0;
}

@media (max-width: 767.98px) {
  .dashboard-table thead {
    display: none;
  }

  .dashboard-table tr {
    display: block;
    padding: 0.5rem 0.9rem;
    border-top: 1px solid var(--bs-border-color-translucent);
  }

  .dashboard-table td {
    display: flex;
    justify-content: space-between;
    gap: 1rem;
    padding: 0.2rem 0;
    border: 0;
    text-align: right;

    &::before {
      content: attr(data-label);
      color: var(--bs-secondary-color);
      font-size: 0.75rem;
      font-weight: 600;
      text-align: left;
    }
  }
}
```

---

# Pruebas

**Editar y eliminar**
- **Un pendiente propio:** en "enviados" muestra Editar y Eliminar. Editar abre el modal con la persona, la categoría y el motivo, y "Guardar cambios" actualiza la tarjeta sin recargar.
- **Uno aprobado o rechazado:** no muestra los botones. Si se llama a la API igual, responde "ya fue aprobado/rechazado: no se puede…".
- **Uno de otra persona:** `PUT` o `DELETE` responden "El reconocimiento no existe".
- **Cambiar a la misma persona y categoría de otro pendiente propio:** "Ya tienes un reconocimiento pendiente…".
- **Al mismo tiempo, administración aprueba mientras el creador edita:** gana uno. El otro recibe el mensaje y, al recargar, la lista muestra el estado real.
- **Eliminar:** pide confirmación en la tarjeta, la quita de la lista y baja el contador.
- **Visibilidad:** un reconocimiento privado sigue privado después de editarlo desde el formulario, que no la envía.

**Cargas masivas**
- **Plantillas:**
  - "Cargar puntos" y "Crear reconocimientos" traen una fila de ejemplo y la hoja Instrucciones.
  - "Aprobar pendientes" trae los pendientes reales con su `id`. Sin pendientes, avisa y no descarga nada.
- **Revisión:**
  - Con una cédula inexistente, puntos en 0 y una categoría inactiva: la revisión muestra cada error con su fila y "Procesar" queda deshabilitado. En la base de datos no cambió nada.
  - Con cédula y correo de personas distintas en la misma fila: "La cédula y el correo no son de la misma persona".
  - Con un archivo de 1.001 filas: error antes de llamar a la API.
- **Puntos:**
  - Un archivo correcto de 3 filas (200, 150, 100): se procesa, aparece "Carga #N" y la pestaña Puntos muestra 3 movimientos.
  - En la base de datos, los 3 movimientos tienen `bulk_load_id = N`.
- **Doble clic en Procesar,** o reenviar la misma petición: la segunda responde "ya se procesó" y no hay movimientos duplicados.
- **Reconocimientos con estado Aprobada y 150 puntos:**
  - Sale en el feed (si es público) y en "Mis reconocimientos" de la persona, con +150 en "Mis puntos".
  - En el libro de puntos, el movimiento tiene el `recognition_id` del reconocimiento creado.
- **Reconocimiento Pendiente con puntos:** "Los puntos solo se asignan a reconocimientos aprobados".
- **Aprobar pendientes:**
  - En 3 filas: Aprobar con 100, Rechazar y vacía. Quedan 1 aprobado con puntos, 1 rechazado y 1 sin tocar ("Sin decisión: 1").
  - Si uno se aprobó individualmente entre la descarga y la carga: "Este reconocimiento ya fue revisado" y no se aplica ninguna fila.
- **Administración en su propia carga:** si quien sube el archivo aparece como destinatario, "No puedes asignarte puntos ni reconocerte a ti mismo".
- **Consultas de control:** las de la [guía de puntos](puntos-dorados-puntos-api.md) y la 4 de [aprobaciones](puntos-dorados-aprobaciones-api.md) devuelven cero filas después de las cargas.

**Dashboard**
- **Las tarjetas:** son cinco; "Usuarios reconocidos" cuenta personas distintas: dos reconocimientos aprobados a la misma persona cuentan 1.
- **Período del 1 al 13 de octubre:** la gráfica de puntos muestra 13 barras (una por día), con los días sin puntos en 0. Con un rango de 4 meses, cuatro barras por mes.
- **La tabla:**
  - Con los filtros de colaborador, estado o categoría, la tabla cambia junto con las tarjetas.
  - El total de la tabla es igual a la tarjeta "Reconocimientos del período".
  - Muestra el estado de cada uno con su color y "Cargar más" trae los siguientes.
- **En el celular:** la tabla se ve como tarjetas, con la etiqueta de cada dato.

---

# ✅ Checklist

**Editar y eliminar**
- [ ] `UpdateAsync`, `DeleteAsync` y `ChangeError` en `GoldenRecognitionService`; acciones `PUT {id}` y `DELETE {id}`.
- [ ] Angular: `update` y `remove` en el servicio, `updateRecognition` y `deleteRecognition` en el facade, `PagedList.remove`.
- [ ] Modal con `mode` e `initialNominee`; "enviados" con Editar, Eliminar y la confirmación.

**Cargas masivas**
- [ ] `GoldenBulkLoads.sql`: tabla `golden_bulk_load` y `bulk_load_id` en movimientos y reconocimientos.
- [ ] `GoldenBulkLoad`, el enum, las configuraciones y el `DbSet`; `BulkLoadId` y `BulkLoad` en las dos entidades.
- [ ] `GoldenPointsCredit` con `Recognition` y `BulkLoad`, que se usan en `CreditAsync`.
- [ ] **Propiedad real de la cédula en `User`** en `UserDirectory` (⬅).
- [ ] `GoldenBulkLoadService` y `GoldenBulkLoadsController` (cuatro acciones con `try/catch` completo); registro del servicio.
- [ ] Angular: `golden-bulk-loads.service.ts`, `golden-bulk-excel.ts`, `app-golden-bulk-load` en Aprobaciones y en Puntos.
- [ ] Carga masiva de prueba borrada (admin y facade).

**Dashboard**
- [ ] Repositorio: `CountRecognizedUsersAsync`, `SumPointsByDayAsync` y `GetRecognitionsPageAsync`.
- [ ] Servicio: `RecognizedUsers`, `PointsGranularity` y `PointsByDate` en `GetAsync`, y `GetRecognitionsAsync`; acción `recognitions`.
- [ ] Angular: dominio, mapper, servicio y facade; cinco tarjetas, gráfica por fecha y tabla del período.

**Pendiente:** activar los permisos de administración (comentados en aprobaciones, dashboard y cargas masivas).

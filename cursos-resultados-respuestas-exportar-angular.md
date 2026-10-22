# 📊 Cursos — Resultados: respuestas anónimas y exportación — Angular

**Lo que cambia en "Resultados del curso":**

| Dónde | Qué |
|---|---|
| **Encabezado** | Dos botones de descarga: **Excel** ("para analizar") y **PDF** ("informe para compartir"). Mientras se genera, el botón muestra un spinner. |
| **Sección nueva "Respuestas (anónimas)"** | Una tarjeta por respuesta. Lleva las estrellas de calidad y utilidad, el conocimiento antes y después (con la diferencia) y el comentario. Tiene filtro por grupo (solo si el anonimato lo permite), el interruptor "Solo con comentarios" y paginación de 10 en 10. |

**Nunca se muestra** nombre, correo ni fecha de una respuesta. Con menos respuestas que el mínimo, solo aparece el aviso de anonimato.

La API está en [cursos-resultados-respuestas-exportar-api.md](cursos-resultados-respuestas-exportar-api.md).

**Base:**
- El código real de `.claude/Cursos y recordatorios`: `course-results-modal`, `CourseProgressFacade` (que el modal provee y `AssignmentUsersComponent` ya usa), `toErrorMessage` y `course-feedback`.
- **Requiere** [cursos-formulario-finalizacion-angular.md](cursos-formulario-finalizacion-angular.md) (las 5 preguntas y el resumen nuevo).

> Si ya aplicaste [cursos-resultados-pagina-y-grupos.md](cursos-resultados-pagina-y-grupos.md), los cambios del modal van en `course-results.page` (mismo HTML, mismo facade).

---

## 1. Archivos

```text
src/app/shared/utils/download.ts                                    nuevo: guardar un archivo descargado

src/app/features/courses/
├── domain/course.model.ts                                          ✏️ respuestas anónimas y formato de exportación
├── domain/course.repository.ts                                     ✏️ getResponses, exportResults
├── infraestructure/course.dto.ts                                   ✏️
├── infraestructure/courses.service.ts                              ✏️
├── application/course-progress.facade.ts                           ✏️ respuestas y descarga
├── presentation/course-responses/                                  nuevo ⭐ la lista de respuestas
└── presentation/course-results-modal/                              ✏️ botones de descarga y la sección nueva
```

---

## 2. Paso 1 — Guardar un archivo: `shared/utils/download.ts`

```ts
/** Lee el nombre del archivo de Content-Disposition (filename*=UTF-8''… o filename=…). */
export function fileNameFrom(contentDisposition: string | null, fallback: string): string {
  if (!contentDisposition) return fallback;

  const encoded = /filename\*=UTF-8''([^;]+)/i.exec(contentDisposition);
  if (encoded) return decodeURIComponent(encoded[1].trim());

  const plain = /filename="?([^";]+)"?/i.exec(contentDisposition);
  return plain ? plain[1].trim() : fallback;
}

/** Descarga un Blob con su nombre, sin abrir otra pestaña. */
export function saveBlob(blob: Blob, fileName: string): void {
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = fileName;
  link.style.display = 'none';
  document.body.appendChild(link);
  link.click();
  link.remove();
  // Después del clic: el navegador ya tomó el archivo.
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
```

> El servicio de certificados hace lo mismo dentro de su `subscribe`. Esta función queda reutilizable.

---

## 3. Paso 2 — Modelo, repositorio y servicio

### `courses/domain/course.model.ts` ✏️ — agrega

```ts
/** Una respuesta del formulario, sin persona y sin fecha. */
export interface AnonymousResponse {
  /** Posición en la lista ("Respuesta 12"). No sigue el orden de envío. */
  readonly number: number;
  /** null = el grupo no se puede mostrar sin romper el anonimato. */
  readonly groupName: string | null;
  /** 0 = sin calificar. */
  readonly satisfaction: number;
  /** 0 = sin calificar. */
  readonly usefulness: number;
  readonly knowledgeBefore: number | null;
  readonly knowledgeAfter: number | null;
  readonly comments: string | null;
}

export interface CourseResponsesQuery {
  /** null = todos los grupos. */
  readonly assignmentId: number | null;
  readonly withComments: boolean;
  readonly page: number;
  readonly pageSize: number;
}

export interface CourseResponsesPage {
  /** false = menos respuestas que el mínimo: no hay items. */
  readonly visible: boolean;
  readonly responses: number;
  readonly minimumResponses: number;
  /** true = se puede filtrar y mostrar por grupo. */
  readonly byGroupAvailable: boolean;
  readonly totalCount: number;
  readonly items: readonly AnonymousResponse[];
}

export type ResultsExportFormat = 'xlsx' | 'pdf';
```

### `courses/domain/course.repository.ts` ✏️ — agrega

```ts
/** Respuestas anónimas del formulario de finalización. */
abstract getResponses(courseId: number, query: CourseResponsesQuery): Observable<CourseResponsesPage>;

/** Los resultados como archivo (Excel o PDF), con el nombre que manda la API. */
abstract exportResults(courseId: number, format: ResultsExportFormat): Observable<{ blob: Blob; fileName: string }>;
```

(Agrega los tipos al import de `./course.model`.)

### `courses/infraestructure/course.dto.ts` ✏️ — agrega

La respuesta tiene la misma forma del modelo, así que el DTO es un alias:

```ts
export type CourseResponsesPageDto = CourseResponsesPage;
```

(con `import { CourseResponsesPage } from '../domain/course.model';`).

### `courses/infraestructure/courses.service.ts` ✏️ — agrega

```ts
getResponses(courseId: number, query: CourseResponsesQuery): Observable<CourseResponsesPage> {
  let params = new HttpParams()
    .set('page', query.page)
    .set('pageSize', query.pageSize)
    .set('withComments', query.withComments);
  if (query.assignmentId !== null) params = params.set('assignmentId', query.assignmentId);

  return this.http
    .get<ApiResponse<CourseResponsesPageDto>>(`${this.baseUrl}/${courseId}/responses`, { params })
    .pipe(map(unwrap));
}

exportResults(courseId: number, format: ResultsExportFormat): Observable<{ blob: Blob; fileName: string }> {
  return this.http
    .get(`${this.baseUrl}/${courseId}/results/export`, {
      params: new HttpParams().set('format', format),
      observe: 'response',
      responseType: 'blob',
    })
    .pipe(
      map((response) => ({
        blob: response.body ?? new Blob(),
        fileName: fileNameFrom(
          response.headers.get('Content-Disposition'),
          `Resultados_${new Date().toISOString().slice(0, 10)}.${format}`,
        ),
      })),
    );
}
```

```ts
import { fileNameFrom } from '@shared/utils/download';
```

> **Si la descarga falla**, la API responde JSON (`{ message }` o `{ hasError, errors }`), pero como se pidió un `Blob`, llega como `Blob`. El facade lo convierte a texto antes de mostrar el mensaje (Paso 3).

---

## 4. Paso 3 — El facade: `course-progress.facade.ts` ✏️

```ts
import { HttpErrorResponse } from '@angular/common/http';
import { saveBlob } from '@shared/utils/download';
import { notifyError, notifySuccess } from '@features/courses/course-feedback';
```

```ts
private readonly _exporting = signal<ResultsExportFormat | null>(null);
/** El formato que se está generando (para el spinner del botón). */
readonly exporting = this._exporting.asReadonly();

loadResponses(query: CourseResponsesQuery): Promise<CourseResponsesPage> {
  return firstValueFrom(this.repository.getResponses(this.courseId, query));
}

async exportResults(format: ResultsExportFormat): Promise<void> {
  if (this._exporting()) return;
  this._exporting.set(format);
  try {
    const { blob, fileName } = await firstValueFrom(this.repository.exportResults(this.courseId, format));
    saveBlob(blob, fileName);
    notifySuccess(format === 'xlsx' ? 'Excel descargado' : 'Informe PDF descargado');
  } catch (e) {
    notifyError(toErrorMessage(await readBlobError(e), 'No se pudo exportar los resultados.'));
  } finally {
    this._exporting.set(null);
  }
}
```

Y al final del archivo:

```ts
/** Con responseType 'blob', el JSON de error llega como Blob: se lee para que toErrorMessage lo entienda. */
async function readBlobError(error: unknown): Promise<unknown> {
  if (!(error instanceof HttpErrorResponse) || !(error.error instanceof Blob)) return error;
  try {
    const body = JSON.parse(await error.error.text());
    return new HttpErrorResponse({ error: body, status: error.status, statusText: error.statusText, url: error.url ?? undefined });
  } catch {
    return error;
  }
}
```

---

## 5. Paso 4 — ⭐ La lista de respuestas: `course-responses`

`presentation/course-responses/` — como `AssignmentUsersComponent`, usa el facade que provee el modal.

### `course-responses.component.ts`

```ts
import { ChangeDetectionStrategy, Component, computed, inject, input, signal } from '@angular/core';
import { toObservable, toSignal } from '@angular/core/rxjs-interop';
import { Subject, catchError, combineLatest, from, map, of, startWith, switchMap } from 'rxjs';
import { CourseProgressFacade } from '../../application/course-progress.facade';
import { AnonymousResponse, AssignmentProgress, CourseResponsesPage } from '../../domain/course.model';

const PAGE_SIZE = 10;

@Component({
  selector: 'app-course-responses',
  templateUrl: './course-responses.component.html',
  styleUrl: './course-responses.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class CourseResponsesComponent {
  private readonly facade = inject(CourseProgressFacade);

  /** Para el filtro por grupo. */
  readonly assignments = input.required<readonly AssignmentProgress[]>();

  readonly assignmentId = signal<number | null>(null);
  readonly withComments = signal(false);
  readonly page = signal(1);
  readonly failed = signal(false);

  readonly stars = [1, 2, 3, 4, 5];

  /** "Reintentar" vuelve a pedir la misma página (una señal no emite si el valor no cambia). */
  private readonly reload$ = new Subject<void>();

  readonly result = toSignal(
    combineLatest([
      toObservable(this.assignmentId),
      toObservable(this.withComments),
      toObservable(this.page),
      this.reload$.pipe(startWith(undefined)),
    ]).pipe(
      switchMap(([assignmentId, withComments, page]) =>
        from(this.facade.loadResponses({ assignmentId, withComments, page, pageSize: PAGE_SIZE })).pipe(
          map((result) => {
            this.failed.set(false);
            return result;
          }),
          catchError(() => {
            this.failed.set(true);
            return of<CourseResponsesPage | null>(null);
          }),
          startWith<CourseResponsesPage | null | undefined>(undefined), // undefined = cargando
        ),
      ),
    ),
    { initialValue: undefined },
  );

  readonly loading = computed(() => this.result() === undefined);
  readonly totalPages = computed(() => Math.max(1, Math.ceil((this.result()?.totalCount ?? 0) / PAGE_SIZE)));

  setGroup(value: string): void {
    this.assignmentId.set(value ? Number(value) : null);
    this.page.set(1);
  }

  setWithComments(value: boolean): void {
    this.withComments.set(value);
    this.page.set(1);
  }

  retry(): void {
    this.reload$.next();
  }

  /** +5, 0 o -2. null si falta alguna de las dos. */
  gain(r: AnonymousResponse): number | null {
    return r.knowledgeBefore !== null && r.knowledgeAfter !== null ? r.knowledgeAfter - r.knowledgeBefore : null;
  }
}
```

### `course-responses.component.html`

```html
<div class="cr">
  @if (result(); as data) {
    @if (!data.visible) {
      <div class="cr__notice">
        <i class="fa-solid fa-shield-halved" aria-hidden="true"></i>
        <p class="mb-0">
          Para proteger el anonimato, las respuestas se muestran a partir de
          <strong>{{ data.minimumResponses }}</strong>. Por ahora hay <strong>{{ data.responses }}</strong>.
        </p>
      </div>
    } @else {
      <!-- Filtros -->
      <div class="cr__filters">
        @if (data.byGroupAvailable) {
          <div class="cr__field">
            <label class="form-label small mb-1" for="cr-group">Grupo</label>
            <select id="cr-group" class="form-select form-select-sm" (change)="setGroup($any($event.target).value)">
              <option value="" [selected]="assignmentId() === null">Todos los grupos</option>
              @for (a of assignments(); track a.id) {
                <option [value]="a.id" [selected]="assignmentId() === a.id">{{ a.groupName || 'Grupo sin nombre' }}</option>
              }
            </select>
          </div>
        } @else {
          <p class="cr__hint">Para proteger el anonimato, las respuestas no se separan por grupo (algún grupo tiene pocas).</p>
        }

        <div class="form-check form-switch mb-0">
          <input class="form-check-input" type="checkbox" role="switch" id="cr-with-comments"
            [checked]="withComments()" (change)="setWithComments($any($event.target).checked)" />
          <label class="form-check-label small" for="cr-with-comments">Solo con comentarios</label>
        </div>

        <span class="cr__count" aria-live="polite">
          {{ data.totalCount }} {{ data.totalCount === 1 ? 'respuesta' : 'respuestas' }}
        </span>
      </div>

      <!-- Respuestas -->
      @if (data.items.length) {
        <ol class="cr__list" [attr.start]="data.items[0].number">
          @for (r of data.items; track r.number) {
            <li class="cr-card">
              <header class="cr-card__head">
                <span class="cr-card__number">Respuesta {{ r.number }}</span>
                @if (r.groupName) {
                  <span class="cr-card__group"><i class="fa-solid fa-user-group" aria-hidden="true"></i> {{ r.groupName }}</span>
                }
              </header>

              <dl class="cr-card__scores">
                <div class="cr-score">
                  <dt>Calidad</dt>
                  <dd>
                    @if (r.satisfaction) {
                      <span class="cr-stars" [attr.aria-label]="r.satisfaction + ' de 5 estrellas'">
                        @for (s of stars; track s) {
                          <i class="fa-star" [class.fa-solid]="s <= r.satisfaction" [class.fa-regular]="s > r.satisfaction" aria-hidden="true"></i>
                        }
                      </span>
                    } @else {
                      <span class="cr-empty">Sin calificar</span>
                    }
                  </dd>
                </div>

                <div class="cr-score">
                  <dt>Utilidad</dt>
                  <dd>
                    @if (r.usefulness) {
                      <span class="cr-stars" [attr.aria-label]="r.usefulness + ' de 5 estrellas'">
                        @for (s of stars; track s) {
                          <i class="fa-star" [class.fa-solid]="s <= r.usefulness" [class.fa-regular]="s > r.usefulness" aria-hidden="true"></i>
                        }
                      </span>
                    } @else {
                      <span class="cr-empty">Sin calificar</span>
                    }
                  </dd>
                </div>

                <div class="cr-score">
                  <dt>Conocimiento</dt>
                  <dd class="cr-knowledge">
                    <span>{{ r.knowledgeBefore ?? '—' }}</span>
                    <i class="fa-solid fa-arrow-right" aria-label="a"></i>
                    <span>{{ r.knowledgeAfter ?? '—' }}</span>
                    <small>/ 10</small>
                    @if (gain(r); as g) {
                      <span class="cr-gain" [class.is-down]="g < 0">{{ g > 0 ? '+' : '' }}{{ g }}</span>
                    }
                  </dd>
                </div>
              </dl>

              @if (r.comments) {
                <blockquote class="cr-card__comment">{{ r.comments }}</blockquote>
              }
            </li>
          }
        </ol>

        <!-- Paginación -->
        @if (totalPages() > 1) {
          <nav class="cr__pager" aria-label="Páginas de respuestas">
            <button type="button" class="btn btn-sm btn-outline-secondary" [disabled]="page() === 1" (click)="page.set(page() - 1)">
              <i class="fa-solid fa-chevron-left me-1" aria-hidden="true"></i> Anteriores
            </button>
            <span class="small">Página {{ page() }} de {{ totalPages() }}</span>
            <button type="button" class="btn btn-sm btn-outline-secondary" [disabled]="page() >= totalPages()" (click)="page.set(page() + 1)">
              Siguientes <i class="fa-solid fa-chevron-right ms-1" aria-hidden="true"></i>
            </button>
          </nav>
        }
      } @else {
        <p class="cr__hint">{{ withComments() ? 'Ninguna respuesta tiene comentarios con este filtro.' : 'Sin respuestas con este filtro.' }}</p>
      }
    }
  } @else if (loading()) {
    <div class="cr__loading" role="status">
      <span class="spinner-border spinner-border-sm me-2" aria-hidden="true"></span> Cargando respuestas…
    </div>
  } @else if (failed()) {
    <div class="cr__hint">
      No se pudieron cargar las respuestas.
      <button type="button" class="btn btn-link btn-sm p-0 align-baseline" (click)="retry()">Reintentar</button>
    </div>
  }
</div>
```

> `data` es la página que llegó de la API; `page()` es la señal con el número de página actual.

### `course-responses.component.scss`

```scss
@use '../../../../../styles/courses-tokens' as tokens;

:host {
  @include tokens.courses-tokens;
  display: block;
}

.cr { display: grid; gap: 0.75rem; }

.cr__notice {
  display: flex;
  gap: 0.6rem;
  align-items: flex-start;
  padding: 0.75rem 1rem;
  border-radius: var(--cu-radius);
  background: var(--cu-gray-100);
  color: var(--cu-gray-700);
}

.cr__filters {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-end;
  gap: 0.75rem 1rem;
}

.cr__field { min-width: 12rem; }
.cr__count { margin-left: auto; color: var(--cu-muted); font-size: 0.85rem; }
.cr__hint { margin: 0; color: var(--cu-muted); font-size: 0.85rem; }
.cr__loading { color: var(--cu-muted); font-size: 0.9rem; }

.cr__list {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(17rem, 1fr));
  gap: 0.75rem;
  margin: 0;
  padding: 0;
  list-style: none;
}

.cr-card {
  display: grid;
  align-content: start;
  gap: 0.6rem;
  padding: 0.875rem 1rem;
  border: 1px solid var(--cu-border);
  border-radius: var(--cu-radius);
  background: var(--cu-surface);
}

.cr-card__head {
  display: flex;
  flex-wrap: wrap;
  justify-content: space-between;
  gap: 0.25rem 0.75rem;
}

.cr-card__number { font-weight: 700; color: var(--cu-text); }

.cr-card__group {
  color: var(--cu-muted);
  font-size: 0.78rem;
}

.cr-card__scores {
  display: grid;
  gap: 0.35rem;
  margin: 0;
}

.cr-score {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 0.5rem;

  dt { color: var(--cu-muted); font-size: 0.8rem; font-weight: 600; }
  dd { margin: 0; }
}

.cr-stars {
  display: inline-flex;
  gap: 0.1rem;
  color: var(--cu-accent);
  font-size: 0.9rem;

  .fa-regular { color: var(--cu-gray-300); }
}

.cr-empty { color: var(--cu-gray-500); font-size: 0.8rem; font-style: italic; }

.cr-knowledge {
  display: inline-flex;
  align-items: center;
  gap: 0.35rem;
  font-weight: 700;

  .fa-arrow-right { color: var(--cu-gray-400); font-size: 0.75rem; }
  small { color: var(--cu-muted); font-weight: 400; }
}

.cr-gain {
  padding: 0.05rem 0.45rem;
  border-radius: 999px;
  background: var(--cu-accent-subtle-bg);
  color: var(--cu-accent-text);
  font-size: 0.78rem;

  &.is-down { background: var(--cu-gray-800); color: #fff; }
}

.cr-card__comment {
  margin: 0;
  padding: 0.5rem 0.75rem;
  border-left: 3px solid var(--cu-accent);
  border-radius: var(--cu-radius-sm);
  background: var(--cu-gray-50);
  color: var(--cu-gray-700);
  font-size: 0.875rem;
  white-space: pre-line;
}

.cr__pager {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 0.5rem;
}
```

---

## 6. Paso 5 — El modal de resultados ✏️

### `course-results-modal.component.ts`

```ts
import { CourseResponsesComponent } from '../course-responses/course-responses.component';
import { ResultsExportFormat } from '../../domain/course.model';
```

```ts
imports: [DecimalPipe, AssignmentUsersComponent, CourseResponsesComponent],
```

```ts
export(format: ResultsExportFormat): void {
  void this.facade.exportResults(format);
}
```

### `course-results-modal.component.html`

**1. En el encabezado**, antes del botón de cerrar:

```html
<div class="rm__export" role="group" aria-label="Descargar resultados">
  <button type="button" class="btn btn-sm btn-yellow" [disabled]="!!facade.exporting() || facade.status() !== 'ready'"
    title="Para analizar: resumen, grupos, personas y respuestas" (click)="export('xlsx')">
    @if (facade.exporting() === 'xlsx') {
      <span class="spinner-border spinner-border-sm me-1" aria-hidden="true"></span>
    } @else {
      <i class="fa-solid fa-file-excel me-1" aria-hidden="true"></i>
    }
    Excel
  </button>
  <button type="button" class="btn btn-sm btn-outline-secondary" [disabled]="!!facade.exporting() || facade.status() !== 'ready'"
    title="Informe para compartir" (click)="export('pdf')">
    @if (facade.exporting() === 'pdf') {
      <span class="spinner-border spinner-border-sm me-1" aria-hidden="true"></span>
    } @else {
      <i class="fa-solid fa-file-pdf me-1" aria-hidden="true"></i>
    }
    PDF
  </button>
</div>
```

**2. Después de la sección "Calificaciones"** (antes de "Personas por grupo"):

```html
<!-- ── Respuestas (anónimas) ──────────────────────────────────── -->
<section class="rm__section" aria-labelledby="rm-responses">
  <h4 id="rm-responses" class="rm__section-title">
    Respuestas
    <span class="rm__anon"><i class="fa-solid fa-user-secret" aria-hidden="true"></i> Anónimas: sin nombre ni fecha</span>
  </h4>
  <app-course-responses [assignments]="assignments()" />
</section>
```

### `course-results-modal.component.scss` ✏️ — agrega

```scss
.rm__export {
  display: flex;
  gap: 0.4rem;
  margin-left: auto;
  margin-right: 0.5rem;
  align-self: center;
}

@media (max-width: 575.98px) {
  .rm__head { flex-wrap: wrap; }
  .rm__export { order: 3; width: 100%; margin: 0.5rem 0 0; }
  .rm__export .btn { flex: 1; }
}
```

---

## 7. Pruebas

**Respuestas**
- **Curso con 2 respuestas:** el aviso "a partir de 3. Por ahora hay 2", sin filtros ni tarjetas.
- **Curso con 12 respuestas:**
  - Tarjetas "Respuesta 1" a "Respuesta 10", con "Siguientes".
  - Cada una con estrellas (o "Sin calificar"), "3 → 8 / 10 +5" y el comentario.
- **Ninguna tarjeta muestra** nombre, correo ni fecha.
- **"Solo con comentarios":** se filtra y vuelve a la página 1. El conteo cambia.
- **Grupo:**
  - Si todos los grupos tienen el mínimo, aparece el filtro y cada tarjeta dice su grupo.
  - Si no, aparece el texto de que no se separan por grupo.
- **Diferencia negativa** (8 → 5): la etiqueta "-3" en gris oscuro.
- **Celular:** las tarjetas en una columna y los botones de descarga a lo ancho debajo del título.

**Descargas**
- **Excel:** el botón muestra el spinner y se descarga `Resultados_<curso>_<fecha>.xlsx`, con el aviso "Excel descargado".
- **PDF:** igual, con el aviso "Informe PDF descargado".
- **Mientras se genera uno,** los dos botones están deshabilitados.
- **Sin `WithExposedHeaders` en la API:** el archivo se llama `Resultados_<fecha>.xlsx` (el nombre de respaldo).
- **API caída:** el aviso "No se pudo exportar los resultados.". Si la API manda un mensaje (por ejemplo, 404 "El curso no existe."), se muestra ese.

---

## ✅ Checklist

- [ ] `shared/utils/download.ts`.
- [ ] Modelo, repositorio y servicio: `getResponses` y `exportResults`.
- [ ] `CourseProgressFacade`: `loadResponses`, `exportResults` y `exporting`.
- [ ] `course-responses` (ts, html, scss).
- [ ] Modal de resultados: botones Excel y PDF, la sección "Respuestas" y sus estilos.

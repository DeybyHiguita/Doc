# 📝 Cursos — Formulario de finalización con 5 preguntas — Angular

**Lo que cambia en pantalla:**

| Dónde | Qué |
|---|---|
| **Mis cursos → Finalizar** (el modal) | 5 preguntas. Las estrellas arrancan en **0 = sin calificar**. Las dos escalas de conocimiento son una línea con los números del 1 al 10. Los comentarios son texto libre. Cada pregunta dice si es obligatoria u opcional. |
| **Editor del curso** | Una sección nueva, "Formulario de finalización", con una casilla "Obligatoria" por pregunta. |
| **Resultados del curso** | Promedios sin contar a quien no calificó, el conocimiento antes y después, y los comentarios (anónimos). |

La API está en [cursos-formulario-finalizacion-api.md](cursos-formulario-finalizacion-api.md).

**Base:** el código real de `.claude/Cursos y recordatorios`:
- `app-star-rating` (ya tiene el botón 0).
- `completion-form-modal`, `CompletionFormFacade` y el editor (`course-form.ts`).
- `course-results-modal`.

---

## 1. Archivos

```text
src/app/shared/
├── utils/completion-questions.ts                                   nuevo: códigos, textos y límites
├── components/scale-rating/                                        nuevo: escala 1 a 10
└── components/star-rating/star-rating.component.ts                 ✏️ etiquetas (0 = sin calificar)

src/app/features/my-courses/
├── domain/my-course.model.ts                                       ✏️ requiredQuestions + CompletionAnswers
├── infraestructure/my-course.dto.ts / my-course.mapper.ts          ✏️
├── domain/my-courses.repository.ts / infraestructure/my-courses.service.ts  ✏️ complete(answers)
├── application/completion-form.facade.ts                           ✏️
├── presentation/completion-form-modal/                             ✏️ las 5 preguntas
└── presentation/completion-form-page/                              🗑️ se borra (no tiene ruta)

src/app/features/courses/
├── domain/course.model.ts                                          ✏️ requiredQuestions y resumen
├── infraestructure/course.dto.ts / course.mapper.ts                ✏️
├── application/course-form.ts                                      ✏️ control requiredQuestions
├── presentation/course-editor/                                     ✏️ sección "Formulario de finalización"
├── presentation/add-group-modal / course-groups-modal              ✏️ requiredQuestions: null
└── presentation/course-results-modal/                              ✏️ resultados de las 5 preguntas
```

> **`completion-form-page`:** `mis-cursos/:id/finalizar` redirige al modal (`?finalizar=`), así que esa página no se usa. Bórrala: con el modelo nuevo dejaría de compilar.

---

## 2. Paso 1 — Lo compartido

### `shared/utils/completion-questions.ts`

```ts
/** Códigos de la API (CompletionQuestions). */
export type CompletionQuestion = 'QUALITY' | 'USEFULNESS' | 'KNOWLEDGE_BEFORE' | 'KNOWLEDGE_AFTER' | 'COMMENTS';

export interface CompletionQuestionInfo {
  readonly code: CompletionQuestion;
  /** La pregunta completa (formulario). */
  readonly text: string;
  /** Nombre corto (editor y resultados). */
  readonly short: string;
}

export const COMPLETION_QUESTIONS: readonly CompletionQuestionInfo[] = [
  {
    code: 'QUALITY',
    text: '¿Cómo calificas la calidad del espacio de formación (contenido, recursos de aprendizaje, metodologías)?',
    short: 'Calidad del espacio de formación',
  },
  {
    code: 'USEFULNESS',
    text: '¿Qué tan útil consideras que fue la información recibida para tu rol o tus funciones?',
    short: 'Utilidad para el rol',
  },
  {
    code: 'KNOWLEDGE_BEFORE',
    text: 'En una escala de 1 a 10, ¿qué nivel de conocimiento tenías sobre las temáticas antes de esta capacitación?',
    short: 'Conocimiento antes',
  },
  {
    code: 'KNOWLEDGE_AFTER',
    text: 'En una escala de 1 a 10, ¿qué nivel de conocimiento consideras que tienes después de la capacitación?',
    short: 'Conocimiento después',
  },
  { code: 'COMMENTS', text: 'Comentarios', short: 'Comentarios' },
];

export const COMMENTS_MAX_LENGTH = 1000;

const KNOWN = new Set<string>(COMPLETION_QUESTIONS.map((q) => q.code));

/** Lo que llega de la API, solo con códigos conocidos. */
export function toCompletionQuestions(codes: readonly string[] | null | undefined): CompletionQuestion[] {
  return (codes ?? []).filter((code): code is CompletionQuestion => KNOWN.has(code));
}
```

### `shared/components/star-rating/star-rating.component.ts` ✏️ — las etiquetas

El 0 pasa a significar "sin calificar". Reemplaza `SATISFACTION_LABELS` y `USEFULNESS_LABELS`:

```ts
export const QUALITY_LABELS = ['Sin calificar', 'Muy deficiente', 'Deficiente', 'Aceptable', 'Buena', 'Excelente'] as const;

export const USEFULNESS_LABELS = ['Sin calificar', 'Nada útil', 'Poco útil', 'Algo útil', 'Útil', 'Muy útil'] as const;
```

Y el comentario de la clase:

```ts
/**
 * Calificación de 0 a 5 con estrellas. 0 = sin calificar.
 * Uso: <app-star-rating [(value)]="quality" label="…" [labels]="QUALITY_LABELS" />
 */
```

El resto del componente no cambia: el botón "0" ya existe y su texto sale de `labels[0]`.

### `shared/components/scale-rating/scale-rating.component.ts`

Una línea con los números del 1 al 10. Se elige uno; tocar el elegido otra vez lo quita.

```ts
import { ChangeDetectionStrategy, Component, ElementRef, computed, input, model, viewChildren } from '@angular/core';

let nextId = 0;

/**
 * Escala numérica (por defecto 1 a 10) en una línea. Empieza sin valor (null).
 * Uso: <app-scale-rating [(value)]="knowledgeBefore" label="…" minHint="Nada" maxHint="Experto" />
 */
@Component({
  selector: 'app-scale-rating',
  templateUrl: './scale-rating.component.html',
  styleUrl: './scale-rating.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class ScaleRatingComponent {
  readonly value = model<number | null>(null);
  readonly label = input.required<string>();
  readonly min = input(1);
  readonly max = input(10);
  readonly minHint = input('');
  readonly maxHint = input('');
  readonly disabled = input(false);
  readonly invalid = input(false);

  readonly id = `scale-rating-${nextId++}`;
  readonly options = computed(() => Array.from({ length: this.max() - this.min() + 1 }, (_, i) => this.min() + i));

  /** Tabindex itinerante: solo una opción entra en el orden de tabulación. */
  readonly focusable = computed(() => this.value() ?? this.min());

  private readonly buttons = viewChildren<ElementRef<HTMLButtonElement>>('option');

  select(option: number): void {
    if (this.disabled()) return;
    this.value.set(this.value() === option ? null : option);
  }

  onKeydown(event: KeyboardEvent): void {
    if (this.disabled()) return;

    const current = this.value() ?? this.min() - 1;
    let next: number | null = null;

    switch (event.key) {
      case 'ArrowRight':
      case 'ArrowUp':
        next = Math.min(this.max(), current + 1);
        break;
      case 'ArrowLeft':
      case 'ArrowDown':
        next = Math.max(this.min(), current - 1);
        break;
      case 'Home':
        next = this.min();
        break;
      case 'End':
        next = this.max();
        break;
    }

    if (next === null) return;

    event.preventDefault();
    this.value.set(next);
    this.buttons()[next - this.min()]?.nativeElement.focus();
  }
}
```

### `scale-rating.component.html`

```html
<div class="scr" role="radiogroup"
     [attr.aria-labelledby]="id + '-label'"
     [attr.aria-invalid]="invalid()"
     [class.is-invalid]="invalid()"
     [class.is-disabled]="disabled()">
  <span class="visually-hidden" [id]="id + '-label'">{{ label() }}</span>

  <div class="scr__line">
    @for (option of options(); track option) {
      <button
        #option
        type="button"
        role="radio"
        class="scr__option"
        [class.is-selected]="value() === option"
        [class.is-below]="value() !== null && option < value()!"
        [attr.aria-checked]="value() === option"
        [attr.aria-label]="option + ' de ' + max()"
        [attr.tabindex]="focusable() === option ? 0 : -1"
        [disabled]="disabled()"
        (click)="select(option)"
        (keydown)="onKeydown($event)">
        {{ option }}
      </button>
    }
  </div>

  @if (minHint() || maxHint()) {
    <div class="scr__hints" aria-hidden="true">
      <span>{{ minHint() }}</span>
      <span>{{ maxHint() }}</span>
    </div>
  }
</div>
```

### `scale-rating.component.scss`

```scss
:host {
  --scr-on: var(--bs-warning);           // la página lo conecta a su acento, como las estrellas
  --scr-line: var(--bs-border-color);

  display: block;
}

.scr {
  padding: 0.25rem 0;
  border-radius: 0.75rem;

  &.is-invalid { box-shadow: 0 0 0 2px color-mix(in srgb, var(--bs-danger) 55%, transparent); }
  &.is-disabled { opacity: 0.6; }
}

.scr__line {
  position: relative;
  display: grid;
  grid-template-columns: repeat(10, minmax(0, 1fr));
  gap: 0.25rem;

  // La línea que une los números.
  &::before {
    position: absolute;
    top: 50%;
    right: 1rem;
    left: 1rem;
    height: 2px;
    background: var(--scr-line);
    content: '';
  }
}

.scr__option {
  position: relative;
  justify-self: center;
  display: grid;
  width: min(2.5rem, 100%);
  aspect-ratio: 1;
  place-items: center;
  border: 2px solid var(--scr-line);
  border-radius: 50%;
  background: var(--bs-body-bg);
  color: var(--bs-body-color);
  font-size: 0.875rem;
  font-weight: 700;
  transition: background-color 0.15s ease, border-color 0.15s ease, transform 0.15s ease;

  &:hover:not(:disabled) { border-color: var(--scr-on); transform: translateY(-1px); }
  &:focus-visible { outline: 2px solid var(--scr-on); outline-offset: 2px; }

  &.is-below { border-color: var(--scr-on); }

  &.is-selected {
    border-color: var(--scr-on);
    background: var(--scr-on);
    color: #111;
    transform: scale(1.08);
  }
}

.scr__hints {
  display: flex;
  justify-content: space-between;
  margin-top: 0.35rem;
  color: var(--bs-secondary-color);
  font-size: 0.75rem;
}

@media (prefers-reduced-motion: reduce) {
  .scr__option { transition: none; }
}
```

> **En un celular de 320 px** caben los 10 círculos en una línea (cada uno se encoge con la columna).

---

## 3. Paso 2 — Mis cursos: modelo, servicio y facade

### `my-courses/domain/my-course.model.ts` ✏️

**1. En `CompletionForm`**, agrega:

```ts
/** Las preguntas que este curso pide obligatoriamente. */
readonly requiredQuestions: readonly CompletionQuestion[];
```

**2. Reemplaza `CompletionRatings`** por:

```ts
/** Lo que se envía. Estrellas: 0 = sin calificar. Escalas: null = sin responder. */
export interface CompletionAnswers {
  readonly satisfaction: number;
  readonly usefulness: number;
  readonly knowledgeBefore: number | null;
  readonly knowledgeAfter: number | null;
  readonly comments: string | null;
}
```

```ts
import { CompletionQuestion } from '@shared/utils/completion-questions';
```

### `infraestructure/my-course.dto.ts` ✏️ — en `CompletionFormDto`

```ts
requiredQuestions: string[];
```

### `infraestructure/my-course.mapper.ts` ✏️ — en `toCompletionForm`

```ts
requiredQuestions: toCompletionQuestions(dto.requiredQuestions),
```

```ts
import { toCompletionQuestions } from '@shared/utils/completion-questions';
```

### `domain/my-courses.repository.ts` y `infraestructure/my-courses.service.ts` ✏️

`CompletionRatings` pasa a `CompletionAnswers`:

```ts
abstract complete(assignmentUserId: number, answers: CompletionAnswers): Observable<string>;
```

```ts
complete(id: number, answers: CompletionAnswers): Observable<string> {
  return this.http
    .post<ApiResponse<{ completedDate: string }>>(`${this.baseUrl}/${id}/complete`, answers)
    .pipe(map(unwrap), map((result) => result.completedDate));
}
```

### `application/completion-form.facade.ts` ✏️

Solo cambia el tipo:

```ts
async complete(answers: CompletionAnswers): Promise<boolean> {
  this._submitting.set(true);
  try {
    const completedDate = await firstValueFrom(this.repository.complete(this.id, answers));
    // … lo demás igual …
```

---

## 4. Paso 3 — ⭐ El modal con las 5 preguntas

### `completion-form-modal.component.ts` ✏️

**1. Imports:**

```ts
import { QUALITY_LABELS, StarRatingComponent, USEFULNESS_LABELS } from '@shared/components/star-rating/star-rating.component';
import { ScaleRatingComponent } from '@shared/components/scale-rating/scale-rating.component';
import { COMMENTS_MAX_LENGTH, COMPLETION_QUESTIONS, CompletionQuestion } from '@shared/utils/completion-questions';
```

```ts
imports: [DatePipe, StarRatingComponent, ScaleRatingComponent],
```

**2. Reemplaza** `satisfactionLabels`, `usefulnessLabels`, las señales `satisfaction`/`usefulness` e `isComplete` por:

```ts
readonly qualityLabels = QUALITY_LABELS;
readonly usefulnessLabels = USEFULNESS_LABELS;
readonly commentsMax = COMMENTS_MAX_LENGTH;
/** Texto de cada pregunta por código. */
readonly question = Object.fromEntries(COMPLETION_QUESTIONS.map((q) => [q.code, q.text])) as Record<CompletionQuestion, string>;

/** Estrellas en 0 = sin calificar (por si la persona no quiere responder). Escalas sin valor. */
readonly quality = signal<number | null>(0);
readonly usefulness = signal<number | null>(0);
readonly knowledgeBefore = signal<number | null>(null);
readonly knowledgeAfter = signal<number | null>(null);
readonly comments = signal('');
readonly submitted = signal(false);

private readonly required = computed(() => new Set(this.facade.form()?.requiredQuestions ?? []));

isRequired(code: CompletionQuestion): boolean {
  return this.required().has(code);
}

/** Las mismas reglas de la API: obligatoria = estrellas de 1 a 5, escala con valor, comentario no vacío. */
readonly errors = computed(() => {
  const missing = new Set<CompletionQuestion>();
  if (this.isRequired('QUALITY') && !this.quality()) missing.add('QUALITY');
  if (this.isRequired('USEFULNESS') && !this.usefulness()) missing.add('USEFULNESS');
  if (this.isRequired('KNOWLEDGE_BEFORE') && this.knowledgeBefore() === null) missing.add('KNOWLEDGE_BEFORE');
  if (this.isRequired('KNOWLEDGE_AFTER') && this.knowledgeAfter() === null) missing.add('KNOWLEDGE_AFTER');
  if (this.isRequired('COMMENTS') && !this.comments().trim()) missing.add('COMMENTS');
  return missing;
});

showError(code: CompletionQuestion): boolean {
  return this.submitted() && this.errors().has(code);
}
```

**3. En el `effect`**, al abrir:

```ts
this.quality.set(0);
this.usefulness.set(0);
this.knowledgeBefore.set(null);
this.knowledgeAfter.set(null);
this.comments.set('');
this.submitted.set(false);
```

**4. En `submit()`:**

```ts
async submit(): Promise<void> {
  this.submitted.set(true);
  if (this.errors().size || this.facade.submitting()) return;

  const confirmed = await confirmDanger(
    '¿Marcar el curso como finalizado?',
    'Después de enviarlo no podrás cambiar tus respuestas.',
    'Sí, finalizar',
  );
  if (!confirmed) return;

  try {
    await this.facade.complete({
      satisfaction: this.quality() ?? 0,
      usefulness: this.usefulness() ?? 0,
      knowledgeBefore: this.knowledgeBefore(),
      knowledgeAfter: this.knowledgeAfter(),
      comments: this.comments().trim() || null,
    });
  } catch (e) {
    notifyError(toErrorMessage(e, 'No se pudo enviar el formulario. Intenta de nuevo.'));
  }
}
```

### `completion-form-modal.component.html` ✏️

Reemplaza los dos `<div class="cf__question">` de "Tu opinión" por las cinco preguntas:

```html
<!-- 1. Calidad -->
<div class="cf__question">
  <p class="cf__question-text">
    <span class="cf__number">1</span> {{ question.QUALITY }}
    <span class="cf__req" [class.is-required]="isRequired('QUALITY')">{{ isRequired('QUALITY') ? 'Obligatoria' : 'Opcional' }}</span>
  </p>
  <app-star-rating
    [(value)]="quality"
    label="Calidad del espacio de formación"
    [labels]="qualityLabels"
    [invalid]="showError('QUALITY')" />
  @if (showError('QUALITY')) {
    <div class="invalid-feedback d-block">Elige de 1 a 5 estrellas.</div>
  }
</div>

<!-- 2. Utilidad -->
<div class="cf__question">
  <p class="cf__question-text">
    <span class="cf__number">2</span> {{ question.USEFULNESS }}
    <span class="cf__req" [class.is-required]="isRequired('USEFULNESS')">{{ isRequired('USEFULNESS') ? 'Obligatoria' : 'Opcional' }}</span>
  </p>
  <app-star-rating
    [(value)]="usefulness"
    label="Utilidad para tu rol o tus funciones"
    [labels]="usefulnessLabels"
    [invalid]="showError('USEFULNESS')" />
  @if (showError('USEFULNESS')) {
    <div class="invalid-feedback d-block">Elige de 1 a 5 estrellas.</div>
  }
</div>

<!-- 3. Conocimiento antes -->
<div class="cf__question">
  <p class="cf__question-text">
    <span class="cf__number">3</span> {{ question.KNOWLEDGE_BEFORE }}
    <span class="cf__req" [class.is-required]="isRequired('KNOWLEDGE_BEFORE')">{{ isRequired('KNOWLEDGE_BEFORE') ? 'Obligatoria' : 'Opcional' }}</span>
  </p>
  <app-scale-rating
    [(value)]="knowledgeBefore"
    label="Nivel de conocimiento antes de la capacitación"
    minHint="Ninguno"
    maxHint="Experto"
    [invalid]="showError('KNOWLEDGE_BEFORE')" />
  @if (showError('KNOWLEDGE_BEFORE')) {
    <div class="invalid-feedback d-block">Elige un número del 1 al 10.</div>
  }
</div>

<!-- 4. Conocimiento después -->
<div class="cf__question">
  <p class="cf__question-text">
    <span class="cf__number">4</span> {{ question.KNOWLEDGE_AFTER }}
    <span class="cf__req" [class.is-required]="isRequired('KNOWLEDGE_AFTER')">{{ isRequired('KNOWLEDGE_AFTER') ? 'Obligatoria' : 'Opcional' }}</span>
  </p>
  <app-scale-rating
    [(value)]="knowledgeAfter"
    label="Nivel de conocimiento después de la capacitación"
    minHint="Ninguno"
    maxHint="Experto"
    [invalid]="showError('KNOWLEDGE_AFTER')" />
  @if (showError('KNOWLEDGE_AFTER')) {
    <div class="invalid-feedback d-block">Elige un número del 1 al 10.</div>
  }
</div>

<!-- 5. Comentarios -->
<div class="cf__question">
  <label class="cf__question-text" for="cf-comments">
    <span class="cf__number">5</span> {{ question.COMMENTS }}
    <span class="cf__req" [class.is-required]="isRequired('COMMENTS')">{{ isRequired('COMMENTS') ? 'Obligatoria' : 'Opcional' }}</span>
  </label>
  <textarea
    id="cf-comments"
    class="form-control"
    rows="3"
    placeholder="¿Qué te gustó? ¿Qué mejorarías?"
    [attr.maxlength]="commentsMax"
    [class.is-invalid]="showError('COMMENTS')"
    [value]="comments()"
    (input)="comments.set($any($event.target).value)"></textarea>
  <div class="d-flex justify-content-between">
    @if (showError('COMMENTS')) {
      <div class="invalid-feedback d-block">Escribe tus comentarios.</div>
    } @else {
      <span></span>
    }
    <small class="text-body-secondary">{{ comments().length }}/{{ commentsMax }}</small>
  </div>
</div>
```

Y en el aviso de anonimato, cambia "Tus calificaciones" por "Tus respuestas":

```html
Tus respuestas se guardan en las estadísticas del curso, <strong>sin tu nombre</strong>.
Nadie puede ver qué respondió cada persona.
```

### `completion-form-modal.component.scss` ✏️ — agrega

```scss
.cf__question-text {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 0.35rem 0.5rem;
}

.cf__number {
  display: inline-grid;
  flex-shrink: 0;
  width: 1.5rem;
  height: 1.5rem;
  place-items: center;
  border-radius: 50%;
  background: rgba(245, 197, 24, 0.18);
  font-size: 0.8rem;
  font-weight: 700;
}

.cf__req {
  padding: 0.05rem 0.5rem;
  border-radius: 999px;
  background: var(--bs-tertiary-bg);
  color: var(--bs-secondary-color);
  font-size: 0.7rem;
  font-weight: 700;
  text-transform: uppercase;

  &.is-required {
    background: #1f2937;
    color: #fff;
  }
}

app-scale-rating {
  --scr-on: #f5c518;
}
```

> El modal ya conecta las estrellas al amarillo del sistema; `--scr-on` hace lo mismo con la escala.

---

## 5. Paso 4 — El editor del curso: preguntas obligatorias

### `courses/domain/course.model.ts` ✏️

```ts
import { CompletionQuestion } from '@shared/utils/completion-questions';
```

**En `CourseDetail`:**

```ts
readonly requiredQuestions: readonly CompletionQuestion[];
```

**En `CourseDraft`:**

```ts
/** null = no cambiar (las pantallas de "Agregar grupo" y "Cambiar fecha" no las tocan). */
readonly requiredQuestions: readonly CompletionQuestion[] | null;
```

### `courses/infraestructure/course.dto.ts` ✏️

```ts
// En CourseDetailDto
requiredQuestions: string[];

// En SaveCourseRequestDto
requiredQuestions: string[] | null;
```

### `courses/infraestructure/course.mapper.ts` ✏️

```ts
// toCourseDetail
requiredQuestions: toCompletionQuestions(dto.requiredQuestions),

// toSaveRequest
requiredQuestions: draft.requiredQuestions ? [...draft.requiredQuestions] : null,
```

### `courses/application/course-form.ts` ✏️

**1. El tipo y la construcción:**

```ts
export type CourseForm = FormGroup<{
  name: FormControl<string>;
  url: FormControl<string>;
  modality: FormControl<CourseModality>;
  externalId: FormControl<string>;
  requiredQuestions: FormControl<CompletionQuestion[]>;
  assignments: FormArray<AssignmentGroupForm>;
}>;
```

```ts
// en createCourseForm
requiredQuestions: fb.control<CompletionQuestion[]>([]),
```

**2. `patchCourseForm`:** en el `patchValue`, `requiredQuestions: [...detail.requiredQuestions],`.

**3. `toCourseDraft`:** `requiredQuestions: [...raw.requiredQuestions],`.

> `resetCourseForm` ya lo deja vacío: `form.reset()` vuelve cada control a su valor inicial.

### `course-editor.component.ts` ✏️

```ts
import { COMPLETION_QUESTIONS, CompletionQuestion } from '@shared/utils/completion-questions';
```

```ts
readonly questions = COMPLETION_QUESTIONS;

isRequired(code: CompletionQuestion): boolean {
  return this.form.controls.requiredQuestions.value.includes(code);
}

toggleRequired(code: CompletionQuestion, checked: boolean): void {
  const current = this.form.controls.requiredQuestions.value;
  const order = COMPLETION_QUESTIONS.map((q) => q.code);
  const next = checked ? [...current, code] : current.filter((item) => item !== code);
  this.form.controls.requiredQuestions.setValue(order.filter((item) => next.includes(item)));
  this.form.controls.requiredQuestions.markAsDirty();
}
```

### `course-editor.component.html` ✏️ — después del `</fieldset>` de "Datos del curso"

```html
<!-- Formulario de finalización -->
<fieldset class="editor-section">
  <legend class="editor-section__title">
    <span class="editor-section__step"><i class="fa-solid fa-list-check" aria-hidden="true"></i></span>
    Formulario de finalización
  </legend>
  <p class="form-text mt-0 mb-2">
    Las 5 preguntas aparecen siempre. Marca las que la persona debe responder para poder finalizar.
  </p>

  <ul class="required-questions">
    @for (q of questions; track q.code; let i = $index) {
      <li class="required-questions__item">
        <div class="form-check form-switch mb-0">
          <input class="form-check-input" type="checkbox" role="switch"
            [id]="'required-' + q.code"
            [checked]="isRequired(q.code)"
            (change)="toggleRequired(q.code, $any($event.target).checked)" />
          <label class="form-check-label" [for]="'required-' + q.code">
            <strong>{{ i + 1 }}. {{ q.short }}</strong>
            <span class="d-block small text-body-secondary">{{ isRequired(q.code) ? 'Obligatoria' : 'Opcional' }}</span>
          </label>
        </div>
      </li>
    }
  </ul>
</fieldset>
```

### `course-editor.component.scss` ✏️ — agrega

```scss
.required-questions {
  display: grid;
  gap: 0.5rem;
  margin: 0;
  padding: 0;
  list-style: none;
}

.required-questions__item {
  padding: 0.6rem 0.75rem;
  border: 1px solid var(--bs-border-color);
  border-radius: 0.6rem;

  &:has(input:checked) {
    border-color: rgba(245, 197, 24, 0.6);
    background: rgba(245, 197, 24, 0.08);
  }
}
```

### `add-group-modal.component.ts` y `course-groups-modal.component.ts` ✏️

Al armar `updatedDraft`, agrega:

```ts
requiredQuestions: null, // no cambia las preguntas obligatorias del curso
```

---

## 6. Paso 5 — Resultados del curso

> Si ya aplicaste [cursos-resultados-pagina-y-grupos.md](cursos-resultados-pagina-y-grupos.md), el mismo cambio va en `course-results.page` en lugar del modal.

### `courses/domain/course.model.ts` ✏️ — `RatingSummary`

```ts
export interface RatingSummary {
  readonly responses: number;
  /** false = menos respuestas que el mínimo: no se muestran promedios. */
  readonly visible: boolean;
  readonly minimumResponses: number;
  readonly satisfactionAverage: number | null;
  readonly usefulnessAverage: number | null;
  /** Índice = estrellas (0 a 5). El 0 cuenta a quienes no calificaron. */
  readonly satisfactionDistribution: readonly number[] | null;
  readonly usefulnessDistribution: readonly number[] | null;
  readonly knowledgeBeforeAverage: number | null;
  readonly knowledgeAfterAverage: number | null;
  /** Índice = nivel (1 a 10). El 0 cuenta a quienes no respondieron. */
  readonly knowledgeBeforeDistribution: readonly number[] | null;
  readonly knowledgeAfterDistribution: readonly number[] | null;
  /** Solo en el resumen del curso. */
  readonly comments: readonly string[] | null;
}
```

En `course.dto.ts`, `RatingSummaryDto` agrega los mismos campos (`number | null`, `number[] | null`, `string[] | null`). `toProgress` ya copia `ratings` con `{ ...dto.ratings }`.

### `course-results-modal.component.ts` ✏️

**1. `RatingQuestion` cuenta a quien no calificó:**

```ts
interface RatingQuestion {
  readonly label: string;
  readonly average: number | null;
  readonly bars: readonly RatingBar[];
  /** Quienes dejaron la pregunta en 0 (sin calificar). */
  readonly skipped: number;
}
```

**2. `toQuestions` y `toBars`:**

```ts
private toQuestions(summary: RatingSummary | null): RatingQuestion[] {
  if (!summary?.visible) return [];
  return [
    { label: 'Calidad del espacio de formación', average: summary.satisfactionAverage, ...toBars(summary.satisfactionDistribution) },
    { label: 'Utilidad para el rol', average: summary.usefulnessAverage, ...toBars(summary.usefulnessDistribution) },
  ];
}
```

```ts
/** Barras de 5 a 1, como se leen las reseñas. El 0 (sin calificar) va aparte. */
function toBars(distribution: readonly number[] | null): { bars: RatingBar[]; skipped: number } {
  const counts = Array.from({ length: 6 }, (_, score) => distribution?.[score] ?? 0);
  const max = Math.max(1, ...counts.slice(1));
  const bars = counts
    .map((count, score) => ({ score, count, width: Math.round((count / max) * 100) }))
    .slice(1)
    .reverse();
  return { bars, skipped: counts[0] };
}
```

**3. El conocimiento antes y después:**

```ts
/** "Antes 4,2 → después 7,8 (+3,6)". null si nadie respondió las dos. */
readonly knowledge = computed(() => {
  const ratings = this.courseRatings();
  if (!ratings?.visible) return null;
  const before = ratings.knowledgeBeforeAverage;
  const after = ratings.knowledgeAfterAverage;
  if (before === null && after === null) return null;
  return { before, after, gain: before !== null && after !== null ? Math.round((after - before) * 10) / 10 : null };
});
```

### `course-results-modal.component.html` ✏️ — en la sección "Calificaciones"

**1. Debajo de las barras de cada pregunta** (dentro del `@for (q of courseQuestions() …)`, después de `</ul>`):

```html
@if (q.skipped) {
  <p class="rm__hint mb-0">{{ q.skipped }} sin calificar</p>
}
```

**2. Después de `<div class="rm__questions">…</div>`:**

```html
@if (knowledge(); as k) {
  <div class="rm-knowledge">
    <div class="rm-knowledge__item">
      <span class="rm-knowledge__label">Conocimiento antes</span>
      <strong>{{ k.before !== null ? (k.before | number: '1.1-1') : '—' }}</strong><small>/ 10</small>
    </div>
    <i class="fa-solid fa-arrow-right rm-knowledge__arrow" aria-hidden="true"></i>
    <div class="rm-knowledge__item">
      <span class="rm-knowledge__label">Conocimiento después</span>
      <strong>{{ k.after !== null ? (k.after | number: '1.1-1') : '—' }}</strong><small>/ 10</small>
    </div>
    @if (k.gain !== null) {
      <span class="rm-knowledge__gain" [class.is-negative]="k.gain < 0">
        {{ k.gain > 0 ? '+' : '' }}{{ k.gain | number: '1.1-1' }}
      </span>
    }
  </div>
}

@if (ratings.comments?.length) {
  <div class="rm-comments">
    <h5 class="rm-comments__title">Comentarios <small>(los {{ ratings.comments!.length }} más recientes)</small></h5>
    <ul class="rm-comments__list">
      @for (comment of ratings.comments; track $index) {
        <li class="rm-comments__item">{{ comment }}</li>
      }
    </ul>
  </div>
}
```

(Va dentro de `@if (ratings.visible) { … }`, donde ya existe la variable `ratings`.)

### `course-results-modal.component.scss` ✏️ — agrega

```scss
.rm-knowledge {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.75rem 1rem;
  margin-top: 1rem;
  padding: 0.875rem 1rem;
  border: 1px solid var(--cu-border);
  border-radius: var(--cu-radius);
}

.rm-knowledge__item {
  display: grid;
  gap: 0.1rem;

  strong { font-size: 1.35rem; line-height: 1; }
  small { color: var(--cu-muted); }
}

.rm-knowledge__label { color: var(--cu-muted); font-size: 0.75rem; }
.rm-knowledge__arrow { color: var(--cu-gray-400); }

.rm-knowledge__gain {
  margin-left: auto;
  padding: 0.25rem 0.7rem;
  border-radius: 999px;
  background: var(--cu-accent-subtle-bg);
  color: var(--cu-accent-text);
  font-weight: 700;

  &.is-negative { background: var(--cu-gray-800); color: #fff; }
}

.rm-comments { margin-top: 1rem; }

.rm-comments__title {
  margin: 0 0 0.5rem;
  font-size: 0.9rem;
  font-weight: 700;

  small { color: var(--cu-muted); font-weight: 400; }
}

.rm-comments__list {
  display: grid;
  gap: 0.5rem;
  max-height: 18rem;
  margin: 0;
  padding: 0;
  overflow-y: auto;
  list-style: none;
}

.rm-comments__item {
  padding: 0.6rem 0.8rem;
  border-left: 3px solid var(--cu-accent);
  border-radius: var(--cu-radius-sm);
  background: var(--cu-gray-50);
  white-space: pre-line;
}
```

---

## 7. Pruebas

**Formulario (Mis cursos)**
- **Curso sin obligatorias:**
  - Las estrellas arrancan en "0 · Sin calificar", las escalas sin número y los comentarios vacíos.
  - Todas dicen "Opcional".
  - "Marcar como finalizado" funciona sin tocar nada.
- **Curso con calidad, conocimiento después y comentarios obligatorios:**
  - Esas tres dicen "Obligatoria" (en gris oscuro).
  - Enviar sin responderlas marca las tres con su mensaje y no llama a la API.
- **Escala:**
  - Tocar el 7 lo marca (y del 1 al 6 se ven con borde amarillo).
  - Tocar el 7 otra vez lo quita.
  - Con el teclado: flechas, Inicio y Fin.
- **Comentarios:** el contador llega a 1000/1000 y no deja escribir más.
- **Celular (320 px):** los 10 números caben en una línea y no hay scroll horizontal.
- **Lector de pantalla:** la escala se anuncia como grupo de opciones y cada número como "7 de 10".

**Editor del curso**
- **La sección "Formulario de finalización":**
  - Muestra las 5 preguntas.
  - Marcar dos y guardar las conserva al volver a abrir el curso.
- **"Agregar grupo" a ese curso:** las obligatorias no cambian.

**Resultados**
- **Con 3 o más respuestas:**
  - Las barras van de 5 a 1 y debajo dice "N sin calificar".
  - El bloque "Conocimiento antes → después" muestra la diferencia (amarilla si sube, gris oscuro si baja).
  - Aparece la lista de comentarios.
- **Con menos respuestas que el mínimo:** solo el aviso de anonimato, sin comentarios.

---

## ✅ Checklist

- [ ] `completion-questions.ts`, `scale-rating` y las etiquetas de `star-rating`.
- [ ] Mis cursos: modelo, DTO, mapper, repositorio, servicio y facade con `CompletionAnswers`.
- [ ] El modal con las 5 preguntas (ts, html, scss).
- [ ] Borrado `completion-form-page`.
- [ ] Cursos:
  - `requiredQuestions` en el modelo, el DTO y el mapper.
  - `course-form.ts`.
  - La sección del editor.
  - `requiredQuestions: null` en los dos modales.
- [ ] Resultados: `RatingSummary`, barras sin el 0, conocimiento y comentarios.

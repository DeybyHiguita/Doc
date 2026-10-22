# 🔔 Cursos — Configuración de alertas — Angular

Las dos pantallas de la configuración de alertas:

| Pantalla | Ruta | Qué hace |
|---|---|---|
| **Configuración general** | `/cursos/alertas` | La que aplica a todos los cursos. Incluye la vista previa "¿qué se enviaría hoy?" y "Enviar ahora". |
| **Configuración de un curso** | `/cursos/:id/alertas` | Dice si el curso usa la general. "Personalizar para este curso" crea una propia, que manda; "Volver a la general" la quita. |

Las dos usan **el mismo formulario** (`app-alert-settings-form`):
- **Las tres alertas a la persona** (bienvenida, recordatorio y urgente), cada una con **sus propias copias**:
  - Casillas para su líder, su gerencia y su dirección.
  - Un buscador de personas para agregar más correos.
- **Los días antes** se escriben como un número (de 0 a 365), sin lista de opciones.
- **El reporte de resultados:** momentos libres (por ejemplo, "10 días antes" o "45 días después") y quién lo recibe (líderes, gerencia, dirección u otros correos).
- **Una línea de tiempo** con cómo quedan los envíos respecto a la fecha límite.

**La API** está en [cursos-alertas-api.md](cursos-alertas-api.md). **Requiere** la cola de correos en Angular ([cursos-cola-correos-angular.md](cursos-cola-correos-angular.md)): ahí se ve el avance de lo que se envía. **Base:** el código real de `.claude/Cursos y recordatorios`:
- Facades con señales y providers por página.
- `unwrap` de `ApiResponse` y `course-feedback` para los avisos.
- `unsavedChangesGuard`.
- `extractEmails`.
- **El buscador de usuarios que ya existe:** `UsersDirectoryRepository` / `UsersDirectoryService` → `GET /api/users/search`.
- Los tokens `--cu-*`, solo con amarillos y grises.

---

## 1. Archivos

```text
src/app/features/course-alerts/
├── domain/
│   ├── course-alerts.model.ts               modelos, límites y textos
│   └── course-alerts.repository.ts          contrato
├── infraestructure/
│   ├── course-alerts.service.ts             HTTP (api/course-alerts)
│   └── course-alerts.providers.ts           + el buscador de usuarios de cursos
├── application/
│   └── course-alert-settings.facade.ts      estado de cada página
└── presentation/
    ├── _course-alerts-page.scss             estilos comunes de las dos páginas
    ├── email-picker/                        buscar personas o pegar correos (chips)
    ├── alert-recipients/                    líder, gerencia, dirección y correos de una alerta
    ├── alert-settings-form/                 ⭐ el formulario compartido
    ├── course-alerts-general-page/          /cursos/alertas
    └── course-alerts-course-page/           /cursos/:id/alertas

✏️ app.routes.ts                              dos rutas
✏️ courses.page (html/ts)                     botón "Configurar alertas"
✏️ course-card (html/ts)                      ícono de campana por curso
✏️ course-results.page.html                   enlace "Alertas de este curso"
✏️ email-logs/domain/email-log.model.ts       nombre de los dos tipos nuevos en "Registro de correos"
```

---

## 2. Paso 1 — Dominio

### `domain/course-alerts.model.ts`

```ts
export type CourseAlertType = 'COURSE_DUE_REMINDER' | 'COURSE_DUE_URGENT' | 'COURSE_RESULTS_REPORT';

/** A quién se copia una alerta (o a quién va el reporte). */
export interface AlertRecipients {
  /** El líder de cada persona (en el reporte: cada líder recibe su equipo). */
  leader: boolean;
  /** Pendiente: el DataLake aún no trae el correo del gerente. */
  management: boolean;
  /** Pendiente: el DataLake aún no trae el correo del director. */
  direction: boolean;
  emails: string[];
}

export interface WelcomeAlert {
  enabled: boolean;
  copy: AlertRecipients;
}

export interface ReminderAlert {
  enabled: boolean;
  /** Días antes de la fecha límite. 0 = el mismo día. */
  daysBefore: number;
  copy: AlertRecipients;
}

export interface ReportAlert {
  enabled: boolean;
  /** -3 = tres días antes, 0 = el día, 3 = tres días después. */
  dayOffsets: number[];
  to: AlertRecipients;
}

export interface CourseAlertSettings {
  welcome: WelcomeAlert;
  reminder: ReminderAlert;
  urgent: ReminderAlert;
  report: ReportAlert;

  /** Solo al leer. */
  updatedDate?: Date | null;
  updatedBy?: string | null;
}

export interface CourseAlertCourseSettings {
  courseId: number;
  courseName: string;
  /** true = no tiene configuración propia: `settings` es la general. */
  usesGeneral: boolean;
  settings: CourseAlertSettings;
}

export interface CourseAlertPreviewItem {
  alertType: CourseAlertType;
  courseName: string;
  groupName: string;
  /** yyyy-MM-dd */
  dueDate: string;
  to: string;
  copies: string[];
}

export interface CourseAlertRunResult {
  date: string;
  dryRun: boolean;
  reminders: number;
  urgent: number;
  reports: number;
  items: CourseAlertPreviewItem[];
}

/** Los mismos límites de la API. */
export const ALERT_LIMITS = { maxDays: 365, maxOffset: 365, maxMoments: 20, maxEmails: 50 } as const;

export const ALERT_TYPE_LABEL: Readonly<Record<CourseAlertType, string>> = {
  COURSE_DUE_REMINDER: 'Recordatorio',
  COURSE_DUE_URGENT: 'Urgente',
  COURSE_RESULTS_REPORT: 'Reporte',
};

const days = (n: number) => `${n} ${n === 1 ? 'día' : 'días'}`;

/** 0 → "El día de la fecha límite"; 7 → "7 días antes". */
export function daysBeforeLabel(daysBefore: number): string {
  return daysBefore === 0 ? 'El día de la fecha límite' : `${days(daysBefore)} antes`;
}

/** -3 → "3 días antes"; 0 → "El día de la fecha límite"; 3 → "3 días después". */
export function momentLabel(offset: number): string {
  if (offset === 0) return 'El día de la fecha límite';
  return offset < 0 ? `${days(-offset)} antes` : `${days(offset)} después`;
}

/** "su líder, 2 correos" · "nadie". */
export function describeRecipients(r: AlertRecipients, report = false): string {
  const parts = [
    r.leader ? (report ? 'los líderes (su equipo)' : 'su líder') : null,
    r.management ? 'gerencia' : null,
    r.direction ? 'dirección' : null,
    r.emails.length ? `${r.emails.length} ${r.emails.length === 1 ? 'correo' : 'correos'}` : null,
  ].filter(Boolean);
  return parts.length ? parts.join(', ') : 'nadie';
}

/** Resumen de solo lectura (página de un curso que usa la general). */
export function describeSettings(s: CourseAlertSettings): { label: string; value: string }[] {
  const copy = (r: AlertRecipients) => ` · copia a ${describeRecipients(r)}`;
  return [
    { label: 'Bienvenida', value: s.welcome.enabled ? `Al asignar el curso${copy(s.welcome.copy)}` : 'Apagada' },
    { label: 'Recordatorio', value: s.reminder.enabled ? `${daysBeforeLabel(s.reminder.daysBefore)}${copy(s.reminder.copy)}` : 'Apagado' },
    { label: 'Urgente', value: s.urgent.enabled ? `${daysBeforeLabel(s.urgent.daysBefore)}${copy(s.urgent.copy)}` : 'Apagada' },
    {
      label: 'Reporte de resultados',
      value: s.report.enabled
        ? `${s.report.dayOffsets.map(momentLabel).join(', ')} · para ${describeRecipients(s.report.to, true)}`
        : 'Apagado',
    },
  ];
}
```

### `domain/course-alerts.repository.ts`

```ts
import { Observable } from 'rxjs';
import { CourseAlertCourseSettings, CourseAlertRunResult, CourseAlertSettings } from './course-alerts.model';

export abstract class CourseAlertsRepository {
  abstract getGeneral(): Observable<CourseAlertSettings>;
  abstract saveGeneral(settings: CourseAlertSettings): Observable<CourseAlertSettings>;

  abstract getForCourse(courseId: number): Observable<CourseAlertCourseSettings>;
  abstract saveForCourse(courseId: number, settings: CourseAlertSettings): Observable<CourseAlertCourseSettings>;
  /** Quita la propia: el curso vuelve a la general. */
  abstract resetCourse(courseId: number): Observable<CourseAlertCourseSettings>;

  /** Qué se encolaría ahora, sin encolar. */
  abstract preview(): Observable<CourseAlertRunResult>;
  /** Encola ya lo que toca hoy (no repite lo que ya está en cola). */
  abstract runNow(): Observable<CourseAlertRunResult>;
}
```

---

## 3. Paso 2 — Infraestructura

### `infraestructure/course-alerts.service.ts`

```ts
import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, map } from 'rxjs';
import { environment } from '../../../../enviroments/enviroment';
import { ApiResponse, unwrap } from '@shared/utils/api-response';
import { CourseAlertCourseSettings, CourseAlertRunResult, CourseAlertSettings } from '../domain/course-alerts.model';
import { CourseAlertsRepository } from '../domain/course-alerts.repository';

type SettingsDto = Omit<CourseAlertSettings, 'updatedDate'> & { updatedDate?: string | null };
type CourseSettingsDto = Omit<CourseAlertCourseSettings, 'settings'> & { settings: SettingsDto };

@Injectable({ providedIn: 'root' })
export class CourseAlertsService implements CourseAlertsRepository {
  private readonly http = inject(HttpClient);
  private readonly baseUrl = `${environment.api.baseUrl}/course-alerts`;

  getGeneral(): Observable<CourseAlertSettings> {
    return this.http.get<ApiResponse<SettingsDto>>(`${this.baseUrl}/general`).pipe(map(unwrap), map(toSettings));
  }

  saveGeneral(settings: CourseAlertSettings): Observable<CourseAlertSettings> {
    return this.http.put<ApiResponse<SettingsDto>>(`${this.baseUrl}/general`, toRequest(settings)).pipe(map(unwrap), map(toSettings));
  }

  getForCourse(courseId: number): Observable<CourseAlertCourseSettings> {
    return this.http.get<ApiResponse<CourseSettingsDto>>(`${this.baseUrl}/courses/${courseId}`).pipe(map(unwrap), map(toCourseSettings));
  }

  saveForCourse(courseId: number, settings: CourseAlertSettings): Observable<CourseAlertCourseSettings> {
    return this.http
      .put<ApiResponse<CourseSettingsDto>>(`${this.baseUrl}/courses/${courseId}`, toRequest(settings))
      .pipe(map(unwrap), map(toCourseSettings));
  }

  resetCourse(courseId: number): Observable<CourseAlertCourseSettings> {
    return this.http.delete<ApiResponse<CourseSettingsDto>>(`${this.baseUrl}/courses/${courseId}`).pipe(map(unwrap), map(toCourseSettings));
  }

  preview(): Observable<CourseAlertRunResult> {
    return this.http.get<ApiResponse<CourseAlertRunResult>>(`${this.baseUrl}/preview`).pipe(map(unwrap));
  }

  runNow(): Observable<CourseAlertRunResult> {
    return this.http.post<ApiResponse<CourseAlertRunResult>>(`${this.baseUrl}/run`, {}).pipe(map(unwrap));
  }
}

/** Las fechas llegan en UTC sin "Z". */
function toSettings(dto: SettingsDto): CourseAlertSettings {
  const iso = dto.updatedDate;
  return { ...dto, updatedDate: iso ? new Date(/[zZ]|[+-]\d{2}:\d{2}$/.test(iso) ? iso : `${iso}Z`) : null };
}

function toCourseSettings(dto: CourseSettingsDto): CourseAlertCourseSettings {
  return { ...dto, settings: toSettings(dto.settings) };
}

/** Solo lo editable (sin la auditoría). */
function toRequest(s: CourseAlertSettings) {
  const { updatedDate: _updatedDate, updatedBy: _updatedBy, ...editable } = s;
  return editable;
}
```

> Igual que `CoursesService`: sin encabezado `Authorization` (lo agrega lo mismo que usan las demás llamadas de cursos) y `unwrap`. Si la API responde `hasError` (validación), `unwrap` lanza el mensaje de la API.

### `infraestructure/course-alerts.providers.ts`

El buscador de personas reutiliza el de cursos (`GET /api/users/search`).

```ts
import { Provider } from '@angular/core';
import { UsersDirectoryRepository } from '@features/courses/domain/users-directory.repository';
import { UsersDirectoryService } from '@features/courses/infraestructure/users-directory.service';
import { CourseAlertsRepository } from '../domain/course-alerts.repository';
import { CourseAlertsService } from './course-alerts.service';

export const COURSE_ALERTS_INFRASTRUCTURE_PROVIDERS: Provider[] = [
  { provide: CourseAlertsRepository, useExisting: CourseAlertsService },
  { provide: UsersDirectoryRepository, useExisting: UsersDirectoryService },
];
```

---

## 4. Paso 3 — El facade

### `application/course-alert-settings.facade.ts`

```ts
import { Injectable, inject, signal } from '@angular/core';
import { firstValueFrom } from 'rxjs';
import { toErrorMessage } from '@shared/utils/api-response';
import { notifyError, notifySuccess } from '@features/courses/course-feedback';
import { CourseAlertCourseSettings, CourseAlertRunResult, CourseAlertSettings } from '../domain/course-alerts.model';
import { CourseAlertsRepository } from '../domain/course-alerts.repository';

type LoadStatus = 'loading' | 'ready' | 'error';

/** Uno por página (providers del componente). */
@Injectable()
export class CourseAlertSettingsFacade {
  private readonly repository = inject(CourseAlertsRepository);

  private readonly _status = signal<LoadStatus>('loading');
  private readonly _error = signal<string | null>(null);
  private readonly _saving = signal(false);
  private readonly _general = signal<CourseAlertSettings | null>(null);
  private readonly _course = signal<CourseAlertCourseSettings | null>(null);
  private readonly _preview = signal<CourseAlertRunResult | null>(null);
  private readonly _previewLoading = signal(false);

  readonly status = this._status.asReadonly();
  readonly error = this._error.asReadonly();
  readonly saving = this._saving.asReadonly();
  readonly general = this._general.asReadonly();
  readonly course = this._course.asReadonly();
  readonly preview = this._preview.asReadonly();
  readonly previewLoading = this._previewLoading.asReadonly();

  // ── General ────────────────────────────────────────────────────────

  async loadGeneral(): Promise<void> {
    await this.load(async () => this._general.set(await firstValueFrom(this.repository.getGeneral())),
      'No se pudo cargar la configuración general.');
  }

  async saveGeneral(settings: CourseAlertSettings): Promise<boolean> {
    return this.save(async () => {
      this._general.set(await firstValueFrom(this.repository.saveGeneral(settings)));
      notifySuccess('Configuración general guardada');
    }, 'No se pudo guardar la configuración.');
  }

  // ── Un curso ───────────────────────────────────────────────────────

  async loadCourse(courseId: number): Promise<void> {
    await this.load(async () => this._course.set(await firstValueFrom(this.repository.getForCourse(courseId))),
      'No se pudo cargar la configuración del curso.');
  }

  async saveCourse(courseId: number, settings: CourseAlertSettings): Promise<boolean> {
    return this.save(async () => {
      this._course.set(await firstValueFrom(this.repository.saveForCourse(courseId, settings)));
      notifySuccess('Configuración del curso guardada');
    }, 'No se pudo guardar la configuración del curso.');
  }

  async resetCourse(courseId: number): Promise<boolean> {
    return this.save(async () => {
      this._course.set(await firstValueFrom(this.repository.resetCourse(courseId)));
      notifySuccess('El curso volvió a la configuración general');
    }, 'No se pudo quitar la configuración del curso.');
  }

  // ── Vista previa y envío ───────────────────────────────────────────

  async loadPreview(): Promise<void> {
    this._previewLoading.set(true);
    try {
      this._preview.set(await firstValueFrom(this.repository.preview()));
    } catch (e) {
      notifyError(toErrorMessage(e, 'No se pudo calcular la vista previa.'));
    } finally {
      this._previewLoading.set(false);
    }
  }

  async runNow(): Promise<CourseAlertRunResult | null> {
    this._previewLoading.set(true);
    try {
      const result = await firstValueFrom(this.repository.runNow());
      this._preview.set(null); // lo encolado ya no está pendiente
      return result;
    } catch (e) {
      notifyError(toErrorMessage(e, 'No se pudieron poner en cola las alertas.'));
      return null;
    } finally {
      this._previewLoading.set(false);
    }
  }

  // ── Privados ───────────────────────────────────────────────────────

  private async load(action: () => Promise<void>, fallback: string): Promise<void> {
    this._status.set('loading');
    this._error.set(null);
    try {
      await action();
      this._status.set('ready');
    } catch (e) {
      this._error.set(toErrorMessage(e, fallback));
      this._status.set('error');
    }
  }

  private async save(action: () => Promise<void>, fallback: string): Promise<boolean> {
    if (this._saving()) return false;
    this._saving.set(true);
    try {
      await action();
      return true;
    } catch (e) {
      // Los errores de validación de la API llegan aquí con su mensaje ("La alerta urgente debe…").
      notifyError(toErrorMessage(e, fallback));
      return false;
    } finally {
      this._saving.set(false);
    }
  }
}
```

---

## 5. Paso 4 — Destinatarios: `email-picker` y `alert-recipients`

### `presentation/email-picker/email-picker.component.ts`

Un campo de correos (`ControlValueAccessor` de `string[]`):
- Busca personas por nombre o correo con el buscador de usuarios que ya existe.
- Si lo escrito es un correo que no está en la base (por ejemplo, `formacion@empresa.co`), ofrece agregarlo tal cual.
- Pegar una lista (de Outlook, Excel o separada por comas) agrega todos los correos de una vez.

```ts
import { ChangeDetectionStrategy, Component, ElementRef, computed, forwardRef, inject, input, signal, viewChild } from '@angular/core';
import { ControlValueAccessor, NG_VALUE_ACCESSOR } from '@angular/forms';
import { toObservable, toSignal } from '@angular/core/rxjs-interop';
import { catchError, debounceTime, distinctUntilChanged, map, of, switchMap, tap } from 'rxjs';
import { extractEmails } from '@shared/utils/email-list';
import { AssignedUser } from '@features/courses/domain/course.model';
import { UsersDirectoryRepository } from '@features/courses/domain/users-directory.repository';

const MIN_TERM = 2;
const SINGLE_EMAIL = /^[a-z0-9._%+'-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}$/i;

@Component({
  selector: 'app-email-picker',
  templateUrl: './email-picker.component.html',
  styleUrl: './email-picker.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
  providers: [{ provide: NG_VALUE_ACCESSOR, useExisting: forwardRef(() => EmailPickerComponent), multi: true }],
})
export class EmailPickerComponent implements ControlValueAccessor {
  private readonly directory = inject(UsersDirectoryRepository);
  private readonly searchInput = viewChild.required<ElementRef<HTMLInputElement>>('search');

  readonly inputId = input.required<string>();
  readonly max = input(50);
  readonly placeholder = input('Busca por nombre o correo, o pega una lista');

  readonly emails = signal<readonly string[]>([]);
  readonly term = signal('');
  readonly focused = signal(false);
  readonly searching = signal(false);
  readonly failed = signal(false);
  readonly disabled = signal(false);
  readonly activeIndex = signal(0);
  readonly message = signal<string | null>(null);

  readonly listId = computed(() => `${this.inputId()}-list`);

  private readonly results = toSignal(
    toObservable(this.term).pipe(
      map((term) => term.trim()),
      debounceTime(300),
      distinctUntilChanged(),
      switchMap((term) =>
        term.length < MIN_TERM
          ? of<AssignedUser[]>([])
          : this.directory.search(term, 8).pipe(
              catchError(() => {
                this.failed.set(true);
                return of<AssignedUser[]>([]);
              }),
            ),
      ),
      tap(() => {
        this.searching.set(false);
        this.activeIndex.set(0);
      }),
    ),
    { initialValue: [] as AssignedUser[] },
  );

  /** Personas con correo que aún no están en la lista. */
  readonly options = computed(() => {
    const chosen = new Set(this.emails());
    return this.results().filter((user) => !!user.email && !chosen.has(user.email.toLowerCase()));
  });

  /** Lo escrito, si es un correo que no salió en la búsqueda: se ofrece agregarlo tal cual. */
  readonly rawEmail = computed(() => {
    const term = this.term().trim().toLowerCase();
    if (!SINGLE_EMAIL.test(term) || this.emails().includes(term)) return null;
    return this.options().some((user) => user.email?.toLowerCase() === term) ? null : term;
  });

  readonly panelOpen = computed(() => this.focused() && this.term().trim().length >= MIN_TERM);
  readonly optionCount = computed(() => this.options().length + (this.rawEmail() ? 1 : 0));
  readonly activeOptionId = computed(() =>
    this.panelOpen() && this.optionCount() ? `${this.listId()}-${this.activeIndex()}` : null,
  );

  private onChange: (value: string[]) => void = () => {};
  private onTouched: () => void = () => {};

  // ── ControlValueAccessor ──────────────────────────────────────────
  writeValue(value: string[] | null): void {
    this.emails.set(value ?? []);
  }

  registerOnChange(fn: (value: string[]) => void): void {
    this.onChange = fn;
  }

  registerOnTouched(fn: () => void): void {
    this.onTouched = fn;
  }

  setDisabledState(isDisabled: boolean): void {
    this.disabled.set(isDisabled);
  }

  // ── Interacción ───────────────────────────────────────────────────
  onInput(value: string): void {
    this.term.set(value);
    this.failed.set(false);
    this.message.set(null);
    this.searching.set(value.trim().length >= MIN_TERM);
  }

  /** Pegar varios correos los agrega todos; pegar uno solo se deja en el buscador. */
  onPaste(event: ClipboardEvent): void {
    const text = event.clipboardData?.getData('text') ?? '';
    const { emails } = extractEmails(text);
    if (emails.length < 2) return;

    event.preventDefault();
    this.addMany(emails);
  }

  onKeydown(event: KeyboardEvent): void {
    const count = this.optionCount();

    switch (event.key) {
      case 'ArrowDown':
        if (!count) return;
        event.preventDefault();
        this.activeIndex.update((i) => (i + 1) % count);
        break;
      case 'ArrowUp':
        if (!count) return;
        event.preventDefault();
        this.activeIndex.update((i) => (i - 1 + count) % count);
        break;
      case 'Enter':
        event.preventDefault(); // Enter nunca envía el formulario
        this.pickActive();
        break;
      case 'Escape':
        if (this.term()) {
          event.stopPropagation();
          this.term.set('');
        }
        break;
      case 'Backspace':
        if (!this.term() && this.emails().length) this.remove(this.emails()[this.emails().length - 1]);
        break;
    }
  }

  pickUser(user: AssignedUser): void {
    if (user.email) this.addMany([user.email]);
  }

  pickRaw(): void {
    const raw = this.rawEmail();
    if (raw) this.addMany([raw]);
  }

  remove(email: string): void {
    this.commit(this.emails().filter((item) => item !== email));
  }

  onBlur(): void {
    this.focused.set(false);
    this.onTouched();
  }

  // ── Privados ──────────────────────────────────────────────────────
  private pickActive(): void {
    if (!this.panelOpen()) return;
    const options = this.options();
    const index = this.activeIndex();
    if (index < options.length) this.pickUser(options[index]);
    else this.pickRaw();
  }

  private addMany(found: readonly string[]): void {
    const merged = [...new Set([...this.emails(), ...found.map((email) => email.trim().toLowerCase())])];
    if (merged.length > this.max()) {
      this.message.set(`Puedes agregar hasta ${this.max()} correos.`);
      return;
    }

    this.commit(merged);
    this.term.set('');
    this.searching.set(false);
    this.searchInput().nativeElement.focus();
  }

  private commit(next: readonly string[]): void {
    this.emails.set(next);
    this.onChange([...next]);
    this.onTouched();
  }
}
```

### `email-picker.component.html`

```html
<div class="ep" [class.is-disabled]="disabled()">
  @if (emails().length) {
    <ul class="ep__chips" aria-label="Correos agregados">
      @for (email of emails(); track email) {
        <li class="ep__chip">
          {{ email }}
          <button type="button" class="ep__remove" [attr.aria-label]="'Quitar ' + email" [disabled]="disabled()" (click)="remove(email)">
            <i class="fa-solid fa-xmark" aria-hidden="true"></i>
          </button>
        </li>
      }
    </ul>
  }

  <div class="ep__search">
    <i class="fa-solid fa-magnifying-glass ep__icon" aria-hidden="true"></i>
    <input
      #search
      type="text"
      class="form-control form-control-sm ep__input"
      role="combobox"
      autocomplete="off"
      aria-autocomplete="list"
      [id]="inputId()"
      [placeholder]="placeholder()"
      [disabled]="disabled()"
      [attr.aria-expanded]="panelOpen()"
      [attr.aria-controls]="listId()"
      [attr.aria-activedescendant]="activeOptionId()"
      [value]="term()"
      (input)="onInput($any($event.target).value)"
      (paste)="onPaste($event)"
      (keydown)="onKeydown($event)"
      (focus)="focused.set(true)"
      (blur)="onBlur()" />

    @if (panelOpen()) {
      <ul class="ep__panel" role="listbox" aria-label="Personas encontradas" [id]="listId()">
        @if (searching()) {
          <li class="ep__status"><span class="spinner-border spinner-border-sm me-2" aria-hidden="true"></span> Buscando…</li>
        } @else {
          @if (failed()) {
            <li class="ep__status">No se pudo buscar. Puedes escribir el correo completo.</li>
          }
          @for (user of options(); track user.id; let i = $index) {
            <li
              role="option"
              class="ep__option"
              [id]="listId() + '-' + i"
              [class.is-active]="i === activeIndex()"
              [attr.aria-selected]="i === activeIndex()"
              (mousedown)="$event.preventDefault(); pickUser(user)"
              (mouseenter)="activeIndex.set(i)">
              <strong>{{ user.displayName }}</strong>
              <small>{{ user.email }}@if (user.jobTitle) { · {{ user.jobTitle }} }</small>
            </li>
          }
          @if (rawEmail(); as raw) {
            <li
              role="option"
              class="ep__option ep__option--raw"
              [id]="listId() + '-' + options().length"
              [class.is-active]="activeIndex() === options().length"
              [attr.aria-selected]="activeIndex() === options().length"
              (mousedown)="$event.preventDefault(); pickRaw()"
              (mouseenter)="activeIndex.set(options().length)">
              <i class="fa-solid fa-plus me-1" aria-hidden="true"></i> Agregar «{{ raw }}»
            </li>
          }
          @if (!options().length && !rawEmail() && !failed()) {
            <li class="ep__status">Sin resultados. Escribe el correo completo para agregarlo.</li>
          }
        }
      </ul>
    }
  </div>

  @if (message(); as text) {
    <div class="form-text ep__message">{{ text }}</div>
  }
</div>
```

### `email-picker.component.scss`

```scss
@use '../../../../../styles/courses-tokens' as tokens;

:host {
  @include tokens.courses-tokens;
  display: block;
}

.ep.is-disabled { opacity: 0.6; }

.ep__chips {
  display: flex;
  flex-wrap: wrap;
  gap: 0.375rem;
  margin: 0 0 0.5rem;
  padding: 0;
  list-style: none;
}

.ep__chip {
  display: inline-flex;
  align-items: center;
  gap: 0.25rem;
  padding: 0.15rem 0.35rem 0.15rem 0.65rem;
  border: 1px solid var(--cu-accent-border);
  border-radius: 999px;
  background: var(--cu-accent-subtle-bg);
  color: var(--cu-accent-text);
  font-size: 0.8rem;
  word-break: break-all;
}

.ep__remove {
  display: grid;
  width: 1.25rem;
  height: 1.25rem;
  place-items: center;
  border: 0;
  border-radius: 50%;
  background: transparent;
  color: inherit;

  &:hover { background: rgba(0, 0, 0, 0.08); }
}

.ep__search { position: relative; }

.ep__icon {
  position: absolute;
  top: 50%;
  left: 0.65rem;
  color: var(--cu-gray-400);
  font-size: 0.8rem;
  transform: translateY(-50%);
  pointer-events: none;
}

.ep__input { padding-left: 1.9rem; }

.ep__panel {
  position: absolute;
  z-index: 20;
  top: calc(100% + 4px);
  right: 0;
  left: 0;
  max-height: 16rem;
  margin: 0;
  padding: 0.25rem;
  overflow-y: auto;
  border: 1px solid var(--cu-border);
  border-radius: var(--cu-radius);
  background: var(--cu-surface);
  box-shadow: var(--cu-shadow-md);
  list-style: none;
}

.ep__option {
  display: grid;
  padding: 0.45rem 0.6rem;
  border-radius: var(--cu-radius-sm);
  cursor: pointer;

  small { color: var(--cu-muted); word-break: break-all; }

  &.is-active { background: var(--cu-accent-subtle-bg); }
  &--raw { display: block; color: var(--cu-accent-text); font-weight: 600; }
}

.ep__status {
  padding: 0.5rem 0.6rem;
  color: var(--cu-muted);
  font-size: 0.85rem;
}

.ep__message { color: var(--cu-gray-800); font-weight: 600; }
```

### `presentation/alert-recipients/alert-recipients.component.ts`

Las casillas y el campo de correos de **una** alerta. Recibe su `FormGroup`.

```ts
import { ChangeDetectionStrategy, Component, input } from '@angular/core';
import { FormControl, FormGroup, ReactiveFormsModule } from '@angular/forms';
import { ALERT_LIMITS } from '../../domain/course-alerts.model';
import { EmailPickerComponent } from '../email-picker/email-picker.component';

export type RecipientsForm = FormGroup<{
  leader: FormControl<boolean>;
  management: FormControl<boolean>;
  direction: FormControl<boolean>;
  emails: FormControl<string[]>;
}>;

@Component({
  selector: 'app-alert-recipients',
  imports: [ReactiveFormsModule, EmailPickerComponent],
  templateUrl: './alert-recipients.component.html',
  styleUrl: './alert-recipients.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class AlertRecipientsComponent {
  readonly group = input.required<RecipientsForm>();
  readonly idPrefix = input.required<string>();
  /** copy = copias de una alerta a la persona; report = destinatarios del reporte. */
  readonly mode = input<'copy' | 'report'>('copy');
  readonly invalid = input(false);

  readonly maxEmails = ALERT_LIMITS.maxEmails;
}
```

### `alert-recipients.component.html`

```html
<fieldset class="ar" [formGroup]="group()" [class.is-invalid]="invalid()">
  <legend class="ar__legend">{{ mode() === 'copy' ? 'Con copia a' : 'Quién recibe el reporte' }}</legend>

  <div class="ar__checks">
    <div class="form-check">
      <input class="form-check-input" type="checkbox" [id]="idPrefix() + '-leader'" formControlName="leader" />
      <label class="form-check-label" [for]="idPrefix() + '-leader'">
        {{ mode() === 'copy' ? 'Su líder' : 'Los líderes' }}
        @if (mode() === 'report') {
          <span class="ar__hint">Cada líder recibe solo su equipo dentro del grupo.</span>
        }
      </label>
    </div>

    <div class="form-check">
      <input class="form-check-input" type="checkbox" [id]="idPrefix() + '-management'" formControlName="management" />
      <label class="form-check-label" [for]="idPrefix() + '-management'">
        {{ mode() === 'copy' ? 'Su gerencia' : 'La gerencia' }} <span class="ar__soon">Pronto</span>
      </label>
    </div>

    <div class="form-check">
      <input class="form-check-input" type="checkbox" [id]="idPrefix() + '-direction'" formControlName="direction" />
      <label class="form-check-label" [for]="idPrefix() + '-direction'">
        {{ mode() === 'copy' ? 'Su dirección' : 'La dirección' }} <span class="ar__soon">Pronto</span>
      </label>
    </div>
  </div>

  @if (group().controls.management.value || group().controls.direction.value) {
    <p class="ar__note">
      Gerencia y dirección se guardan, pero aún no se envían: falta que el maestro de empleados traiga el correo del responsable.
    </p>
  }

  <label class="form-label small mb-1" [for]="idPrefix() + '-emails'">
    {{ mode() === 'copy' ? 'Otras personas en copia' : 'Otros correos' }}
  </label>
  <app-email-picker formControlName="emails" [inputId]="idPrefix() + '-emails'" [max]="maxEmails" />
</fieldset>
```

### `alert-recipients.component.scss`

```scss
@use '../../../../../styles/courses-tokens' as tokens;

:host {
  @include tokens.courses-tokens;
  display: block;
}

.ar {
  display: grid;
  gap: 0.5rem;
  margin: 0;
  padding: 0.75rem;
  border: 1px dashed var(--cu-border);
  border-radius: var(--cu-radius);
  background: var(--cu-gray-50);

  &.is-invalid { border-color: var(--cu-gray-800); border-style: solid; }
}

.ar__legend {
  float: none;
  width: auto;
  margin: 0;
  padding: 0;
  color: var(--cu-gray-700);
  font-size: 0.78rem;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.04em;
}

.ar__checks { display: grid; gap: 0.25rem; }

.ar__hint {
  display: block;
  color: var(--cu-muted);
  font-size: 0.75rem;
}

.ar__soon {
  margin-left: 0.25rem;
  padding: 0.05rem 0.45rem;
  border-radius: 999px;
  background: var(--cu-gray-200);
  color: var(--cu-gray-600);
  font-size: 0.62rem;
  font-weight: 700;
  text-transform: uppercase;
}

.ar__note {
  margin: 0;
  color: var(--cu-gray-600);
  font-size: 0.75rem;
}
```

---

## 6. Paso 5 — ⭐ `alert-settings-form` (el formulario compartido)

`presentation/alert-settings-form/`

### `alert-settings-form.component.ts`

```ts
import { ChangeDetectionStrategy, Component, computed, effect, inject, input, output, signal, untracked } from '@angular/core';
import { AbstractControl, NonNullableFormBuilder, ReactiveFormsModule, ValidationErrors, ValidatorFn, Validators } from '@angular/forms';
import { takeUntilDestroyed, toSignal } from '@angular/core/rxjs-interop';
import { map } from 'rxjs';
import {
  ALERT_LIMITS,
  AlertRecipients,
  CourseAlertSettings,
  daysBeforeLabel,
  momentLabel,
} from '../../domain/course-alerts.model';
import { AlertRecipientsComponent, RecipientsForm } from '../alert-recipients/alert-recipients.component';

type Tone = 'accent' | 'dark' | 'gray' | 'due';
interface TimelineItem { offset: number; title: string; detail: string; tone: Tone }
type MomentWhen = 'before' | 'on' | 'after';

/** Solo enteros (el input number acepta "2.5"). */
const wholeNumber: ValidatorFn = (control) =>
  control.value === null || Number.isInteger(control.value) ? null : { wholeNumber: true };

/** Las mismas reglas de la API, para avisar antes de enviar. */
function settingsValidator(group: AbstractControl): ValidationErrors | null {
  const v = group.value as CourseAlertSettings;
  const errors: ValidationErrors = {};

  if (v.reminder.enabled && v.urgent.enabled && v.urgent.daysBefore >= v.reminder.daysBefore) {
    errors['urgentNotCloser'] = true;
  }

  if (v.report.enabled && !v.report.dayOffsets.length) errors['reportWithoutMoments'] = true;

  const to = v.report.to;
  if (v.report.enabled && !to.leader && !to.management && !to.direction && !to.emails.length) {
    errors['reportWithoutRecipients'] = true;
  }

  return Object.keys(errors).length ? errors : null;
}

@Component({
  selector: 'app-alert-settings-form',
  imports: [ReactiveFormsModule, AlertRecipientsComponent],
  templateUrl: './alert-settings-form.component.html',
  styleUrl: './alert-settings-form.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class AlertSettingsFormComponent {
  private readonly fb = inject(NonNullableFormBuilder);

  readonly value = input.required<CourseAlertSettings>();
  readonly saving = input(false);
  readonly submitLabel = input('Guardar configuración');

  readonly save = output<CourseAlertSettings>();
  /** La página lo usa para "¿Salir sin guardar?". */
  readonly dirtyChange = output<boolean>();

  readonly limits = ALERT_LIMITS;
  readonly daysBeforeLabel = daysBeforeLabel;
  readonly momentLabel = momentLabel;

  readonly form = this.fb.group(
    {
      welcome: this.fb.group({ enabled: [true], copy: this.recipients() }),
      reminder: this.fb.group({ enabled: [true], daysBefore: [7, this.daysValidators()], copy: this.recipients() }),
      urgent: this.fb.group({ enabled: [true], daysBefore: [2, this.daysValidators()], copy: this.recipients() }),
      report: this.fb.group({
        enabled: [false],
        dayOffsets: this.fb.control<number[]>([]),
        to: this.recipients(),
      }),
    },
    { validators: settingsValidator },
  );

  /** El valor del formulario como señal (para la línea de tiempo y los avisos). */
  readonly current = toSignal(this.form.valueChanges.pipe(map(() => this.form.getRawValue())), {
    initialValue: this.form.getRawValue(),
  });

  // ── Agregar un momento del reporte ─────────────────────────────────
  readonly momentDays = signal<number | null>(3);
  readonly momentWhen = signal<MomentWhen>('after');
  readonly momentError = signal<string | null>(null);

  /** Cómo quedan los envíos respecto a la fecha límite, de izquierda a derecha. */
  readonly timeline = computed<TimelineItem[]>(() => {
    const v = this.current();
    const items: TimelineItem[] = [{ offset: 0, title: 'Fecha límite', detail: 'Día de cierre', tone: 'due' }];

    if (v.reminder.enabled) {
      items.push({ offset: -v.reminder.daysBefore, title: 'Recordatorio', detail: daysBeforeLabel(v.reminder.daysBefore), tone: 'accent' });
    }
    if (v.urgent.enabled) {
      items.push({ offset: -v.urgent.daysBefore, title: 'Urgente', detail: daysBeforeLabel(v.urgent.daysBefore), tone: 'dark' });
    }
    if (v.report.enabled) {
      for (const offset of v.report.dayOffsets) {
        items.push({ offset, title: 'Reporte', detail: momentLabel(offset), tone: 'gray' });
      }
    }

    return items.sort((a, b) => a.offset - b.offset);
  });

  constructor() {
    // Cada vez que la página entrega un valor (al cargar o después de guardar), el formulario vuelve a él.
    effect(() => {
      const value = this.value();
      untracked(() => {
        this.form.reset({
          welcome: { enabled: value.welcome.enabled, copy: copyOf(value.welcome.copy) },
          reminder: { enabled: value.reminder.enabled, daysBefore: value.reminder.daysBefore, copy: copyOf(value.reminder.copy) },
          urgent: { enabled: value.urgent.enabled, daysBefore: value.urgent.daysBefore, copy: copyOf(value.urgent.copy) },
          report: { enabled: value.report.enabled, dayOffsets: [...value.report.dayOffsets], to: copyOf(value.report.to) },
        });
        this.momentError.set(null);
        this.dirtyChange.emit(false);
      });
    });

    this.form.valueChanges.pipe(takeUntilDestroyed()).subscribe(() => this.dirtyChange.emit(this.form.dirty));
  }

  addMoment(): void {
    const when = this.momentWhen();
    const days = when === 'on' ? 0 : this.momentDays();

    if (days === null || !Number.isInteger(days) || days < (when === 'on' ? 0 : 1) || days > this.limits.maxOffset) {
      this.momentError.set(`Escribe un número de días entre 1 y ${this.limits.maxOffset}.`);
      return;
    }

    const offset = when === 'before' ? -days : days;
    const current = this.form.controls.report.controls.dayOffsets.value;

    if (current.includes(offset)) {
      this.momentError.set(`"${momentLabel(offset)}" ya está en la lista.`);
      return;
    }

    if (current.length >= this.limits.maxMoments) {
      this.momentError.set(`Puedes tener hasta ${this.limits.maxMoments} momentos.`);
      return;
    }

    this.form.controls.report.controls.dayOffsets.setValue([...current, offset].sort((a, b) => a - b));
    this.form.markAsDirty();
    this.momentError.set(null);
  }

  removeMoment(offset: number): void {
    const control = this.form.controls.report.controls.dayOffsets;
    control.setValue(control.value.filter((item) => item !== offset));
    this.form.markAsDirty();
  }

  hasDaysError(alert: 'reminder' | 'urgent'): boolean {
    const control = this.form.controls[alert].controls.daysBefore;
    return control.invalid && (control.touched || control.dirty);
  }

  submit(): void {
    this.form.markAllAsTouched();
    if (this.form.invalid || this.saving()) return;
    this.save.emit(this.form.getRawValue());
  }

  // ── Privados ───────────────────────────────────────────────────────

  private recipients(): RecipientsForm {
    return this.fb.group({
      leader: [false],
      management: [false],
      direction: [false],
      emails: this.fb.control<string[]>([]),
    });
  }

  private daysValidators(): ValidatorFn[] {
    return [Validators.required, Validators.min(0), Validators.max(ALERT_LIMITS.maxDays), wholeNumber];
  }
}

function copyOf(r: AlertRecipients): AlertRecipients {
  return { leader: r.leader, management: r.management, direction: r.direction, emails: [...r.emails] };
}
```

### `alert-settings-form.component.html`

```html
<form class="asf" [formGroup]="form" (ngSubmit)="submit()" novalidate>

  <!-- ── 1. Alertas a la persona ──────────────────────────────────── -->
  <section class="asf-card" aria-labelledby="asf-person-title">
    <header class="asf-card__head">
      <span class="asf-card__icon"><i class="fa-solid fa-envelope" aria-hidden="true"></i></span>
      <div>
        <h2 id="asf-person-title" class="asf-card__title">Alertas a la persona</h2>
        <p class="asf-card__hint">
          Cada alerta tiene sus propias copias: llegan en CC del mismo correo de la persona.
          Los recordatorios solo llegan a quien no ha diligenciado el formulario de finalización.
        </p>
      </div>
    </header>

    <div class="asf-alerts">
      <!-- Bienvenida -->
      <article class="asf-alert" formGroupName="welcome" [class.is-off]="!current().welcome.enabled">
        <div class="asf-alert__top">
          <span class="asf-alert__badge" data-tone="gray">1</span>
          <div class="asf-alert__text">
            <h3>Bienvenida</h3>
            <p>Al asignarle el curso.</p>
          </div>
          <div class="form-check form-switch ms-auto">
            <input class="form-check-input" type="checkbox" role="switch" id="asf-welcome" formControlName="enabled"
              aria-label="Enviar la bienvenida" />
          </div>
        </div>
        @if (current().welcome.enabled) {
          <app-alert-recipients idPrefix="asf-welcome-copy" [group]="form.controls.welcome.controls.copy" />
        }
      </article>

      <!-- Recordatorio normal -->
      <article class="asf-alert" formGroupName="reminder" [class.is-off]="!current().reminder.enabled">
        <div class="asf-alert__top">
          <span class="asf-alert__badge" data-tone="accent">2</span>
          <div class="asf-alert__text">
            <h3>Recordatorio</h3>
            <p>"Tienes un curso pendiente".</p>
          </div>
          <div class="form-check form-switch ms-auto">
            <input class="form-check-input" type="checkbox" role="switch" id="asf-reminder" formControlName="enabled"
              aria-label="Enviar el recordatorio" />
          </div>
        </div>
        @if (current().reminder.enabled) {
          <label class="form-label small mb-1" for="asf-reminder-days">Cuántos días antes de la fecha límite</label>
          <div class="input-group input-group-sm asf-days">
            <input id="asf-reminder-days" type="number" inputmode="numeric" class="form-control"
              min="0" [max]="limits.maxDays" step="1" formControlName="daysBefore"
              [class.is-invalid]="hasDaysError('reminder')" aria-describedby="asf-reminder-days-help" />
            <span class="input-group-text">días antes</span>
          </div>
          <div id="asf-reminder-days-help" class="form-text mt-0">
            @if (hasDaysError('reminder')) {
              <span class="asf-inline-error">Un número entero de 0 a {{ limits.maxDays }}.</span>
            } @else {
              {{ daysBeforeLabel(current().reminder.daysBefore) }} · 0 = el mismo día.
            }
          </div>
          <app-alert-recipients idPrefix="asf-reminder-copy" [group]="form.controls.reminder.controls.copy" />
        }
      </article>

      <!-- Urgente -->
      <article class="asf-alert asf-alert--urgent" formGroupName="urgent" [class.is-off]="!current().urgent.enabled">
        <div class="asf-alert__top">
          <span class="asf-alert__badge" data-tone="dark">3</span>
          <div class="asf-alert__text">
            <h3>Urgente</h3>
            <p>"Tu curso está por vencer".</p>
          </div>
          <div class="form-check form-switch ms-auto">
            <input class="form-check-input" type="checkbox" role="switch" id="asf-urgent" formControlName="enabled"
              aria-label="Enviar la alerta urgente" />
          </div>
        </div>
        @if (current().urgent.enabled) {
          <label class="form-label small mb-1" for="asf-urgent-days">Cuántos días antes de la fecha límite</label>
          <div class="input-group input-group-sm asf-days">
            <input id="asf-urgent-days" type="number" inputmode="numeric" class="form-control"
              min="0" [max]="limits.maxDays" step="1" formControlName="daysBefore"
              [class.is-invalid]="hasDaysError('urgent')" aria-describedby="asf-urgent-days-help" />
            <span class="input-group-text">días antes</span>
          </div>
          <div id="asf-urgent-days-help" class="form-text mt-0">
            @if (hasDaysError('urgent')) {
              <span class="asf-inline-error">Un número entero de 0 a {{ limits.maxDays }}.</span>
            } @else {
              {{ daysBeforeLabel(current().urgent.daysBefore) }} · 0 = el mismo día.
            }
          </div>
          <app-alert-recipients idPrefix="asf-urgent-copy" [group]="form.controls.urgent.controls.copy" />
        }
      </article>
    </div>

    @if (form.errors?.['urgentNotCloser']) {
      <div class="asf-error" role="alert">La alerta urgente debe enviarse más cerca de la fecha límite que el recordatorio.</div>
    }
  </section>

  <!-- ── 2. Reporte de resultados ─────────────────────────────────── -->
  <section class="asf-card" formGroupName="report" aria-labelledby="asf-report-title">
    <header class="asf-card__head">
      <span class="asf-card__icon"><i class="fa-solid fa-chart-column" aria-hidden="true"></i></span>
      <div class="flex-grow-1">
        <h2 id="asf-report-title" class="asf-card__title">Reporte de resultados</h2>
        <p class="asf-card__hint">Por grupo: cuántos finalizaron y cuántos faltan, con sus nombres, y las calificaciones (anónimas). Cada destinatario recibe su propio correo.</p>
      </div>
      <div class="form-check form-switch">
        <input class="form-check-input" type="checkbox" role="switch" id="asf-report" formControlName="enabled"
          aria-label="Enviar el reporte de resultados" />
      </div>
    </header>

    @if (current().report.enabled) {
      <fieldset class="asf-moments">
        <legend class="form-label fw-semibold">Cuándo (respecto a la fecha límite de cada grupo)</legend>

        @if (current().report.dayOffsets.length) {
          <ul class="asf-moments__list" aria-label="Momentos del reporte">
            @for (offset of current().report.dayOffsets; track offset) {
              <li class="asf-moment">
                {{ momentLabel(offset) }}
                <button type="button" class="asf-moment__remove" [attr.aria-label]="'Quitar ' + momentLabel(offset)" (click)="removeMoment(offset)">
                  <i class="fa-solid fa-xmark" aria-hidden="true"></i>
                </button>
              </li>
            }
          </ul>
        }

        <div class="asf-moments__add">
          @if (momentWhen() !== 'on') {
            <label class="visually-hidden" for="asf-moment-days">Días</label>
            <input id="asf-moment-days" type="number" inputmode="numeric" class="form-control form-control-sm asf-moments__days"
              min="1" [max]="limits.maxOffset" step="1"
              [value]="momentDays() ?? ''"
              (input)="momentDays.set($any($event.target).value === '' ? null : +$any($event.target).value)"
              (keydown.enter)="$event.preventDefault(); addMoment()" />
          }
          <label class="visually-hidden" for="asf-moment-when">Antes o después</label>
          <select id="asf-moment-when" class="form-select form-select-sm asf-moments__when"
            [value]="momentWhen()" (change)="momentWhen.set($any($event.target).value)">
            <option value="before" [selected]="momentWhen() === 'before'">días antes</option>
            <option value="on" [selected]="momentWhen() === 'on'">el día de la fecha límite</option>
            <option value="after" [selected]="momentWhen() === 'after'">días después</option>
          </select>
          <button type="button" class="btn btn-sm btn-outline-secondary" (click)="addMoment()">
            <i class="fa-solid fa-plus me-1" aria-hidden="true"></i> Agregar
          </button>
        </div>

        @if (momentError(); as text) {
          <div class="asf-inline-error mt-1" role="alert">{{ text }}</div>
        } @else {
          <div class="form-text">Cualquier número de días, hasta {{ limits.maxMoments }} momentos.</div>
        }
      </fieldset>
      @if (form.errors?.['reportWithoutMoments'] && form.touched) {
        <div class="asf-error" role="alert">Agrega al menos un momento.</div>
      }

      <app-alert-recipients
        idPrefix="asf-report-to"
        mode="report"
        [group]="form.controls.report.controls.to"
        [invalid]="!!form.errors?.['reportWithoutRecipients'] && form.touched" />
      @if (form.errors?.['reportWithoutRecipients'] && form.touched) {
        <div class="asf-error" role="alert">Elige quién recibe el reporte: líderes, gerencia, dirección u otros correos.</div>
      }
    }
  </section>

  <!-- ── Línea de tiempo ──────────────────────────────────────────── -->
  <section class="asf-card asf-timeline" aria-labelledby="asf-timeline-title">
    <h2 id="asf-timeline-title" class="asf-card__title">Así quedan los envíos</h2>
    <ol class="asf-timeline__list">
      <li class="asf-timeline__item" data-tone="gray">
        <span class="asf-timeline__dot" aria-hidden="true"></span>
        <strong>Asignación</strong>
        <small>{{ current().welcome.enabled ? 'Bienvenida' : 'Sin bienvenida' }}</small>
      </li>
      @for (item of timeline(); track item.title + item.offset) {
        <li class="asf-timeline__item" [attr.data-tone]="item.tone">
          <span class="asf-timeline__dot" aria-hidden="true"></span>
          <strong>{{ item.title }}</strong>
          <small>{{ item.detail }}</small>
        </li>
      }
    </ol>
  </section>

  <div class="asf-actions">
    <ng-content select="[asfExtraActions]" />
    <button type="submit" class="btn btn-yellow" [disabled]="saving()">
      @if (saving()) {
        <span class="spinner-border spinner-border-sm me-1" aria-hidden="true"></span> Guardando…
      } @else {
        <i class="fa-solid fa-floppy-disk me-1" aria-hidden="true"></i> {{ submitLabel() }}
      }
    </button>
  </div>
</form>
```

### `alert-settings-form.component.scss`

```scss
@use '../../../../../styles/courses-tokens' as tokens;

:host {
  @include tokens.courses-tokens;
  display: block;
}

.asf { display: grid; gap: 1rem; }

.asf-card {
  display: grid;
  gap: 0.875rem;
  padding: 1.25rem 1.5rem;
  border: 1px solid var(--cu-border);
  border-radius: var(--cu-radius-lg);
  background: var(--cu-surface);
  box-shadow: var(--cu-shadow-sm);
}

.asf-card__head {
  display: flex;
  align-items: flex-start;
  gap: 0.75rem;
}

.asf-card__icon {
  display: grid;
  flex-shrink: 0;
  width: 40px;
  height: 40px;
  place-items: center;
  border-radius: 10px;
  background: var(--cu-accent-subtle-bg);
  color: var(--cu-accent-text);
}

.asf-card__title { margin: 0; font-size: 1.05rem; font-weight: 700; }
.asf-card__hint { margin: 0.15rem 0 0; color: var(--cu-muted); font-size: 0.85rem; }

.asf-error {
  padding: 0.5rem 0.75rem;
  border-left: 3px solid var(--cu-gray-800);
  border-radius: var(--cu-radius-sm);
  background: var(--cu-gray-100);
  color: var(--cu-gray-800);
  font-size: 0.85rem;
}

.asf-inline-error { color: var(--cu-gray-800); font-size: 0.8rem; font-weight: 600; }

// ── Las tres alertas ────────────────────────────────────────────────
.asf-alerts {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 0.75rem;
  align-items: start;
}

.asf-alert {
  display: grid;
  align-content: start;
  gap: 0.5rem;
  padding: 0.875rem;
  border: 1.5px solid var(--cu-border);
  border-radius: var(--cu-radius);
  background: var(--cu-surface);
  transition: opacity 0.2s ease, border-color 0.2s ease;

  &.is-off { opacity: 0.6; }
  &--urgent:not(.is-off) { border-color: var(--cu-gray-700); }
}

.asf-alert__top { display: flex; align-items: flex-start; gap: 0.6rem; }
.asf-alert__text h3 { margin: 0; font-size: 0.95rem; font-weight: 700; }
.asf-alert__text p { margin: 0; color: var(--cu-muted); font-size: 0.78rem; }

.asf-alert__badge {
  display: grid;
  flex-shrink: 0;
  width: 26px;
  height: 26px;
  place-items: center;
  border-radius: 50%;
  font-size: 0.8rem;
  font-weight: 700;

  &[data-tone='gray'] { background: var(--cu-gray-200); color: var(--cu-gray-700); }
  &[data-tone='accent'] { background: var(--cu-accent); color: var(--cu-on-accent); }
  &[data-tone='dark'] { background: var(--cu-gray-800); color: #fff; }
}

.asf-days { max-width: 12rem; }

// ── Momentos del reporte ────────────────────────────────────────────
.asf-moments { margin: 0; padding: 0; border: 0; }

.asf-moments__list {
  display: flex;
  flex-wrap: wrap;
  gap: 0.4rem;
  margin: 0 0 0.6rem;
  padding: 0;
  list-style: none;
}

.asf-moment {
  display: inline-flex;
  align-items: center;
  gap: 0.25rem;
  padding: 0.25rem 0.35rem 0.25rem 0.8rem;
  border: 1.5px solid var(--cu-accent);
  border-radius: 999px;
  background: var(--cu-accent-subtle-bg);
  color: var(--cu-accent-text);
  font-size: 0.82rem;
  font-weight: 600;
}

.asf-moment__remove {
  display: grid;
  width: 1.3rem;
  height: 1.3rem;
  place-items: center;
  border: 0;
  border-radius: 50%;
  background: transparent;
  color: inherit;

  &:hover { background: rgba(0, 0, 0, 0.08); }
}

.asf-moments__add {
  display: flex;
  flex-wrap: wrap;
  gap: 0.4rem;
  align-items: center;
}

.asf-moments__days { width: 5.5rem; }
.asf-moments__when { width: auto; }

// ── Línea de tiempo ─────────────────────────────────────────────────
.asf-timeline__list {
  display: flex;
  gap: 0;
  margin: 0;
  padding: 0.25rem 0 0;
  overflow-x: auto;
  list-style: none;
}

.asf-timeline__item {
  --dot: var(--cu-gray-400);

  position: relative;
  display: grid;
  flex: 1 0 7.5rem;
  justify-items: center;
  gap: 0.15rem;
  padding: 0 0.25rem;
  text-align: center;

  // La línea que une los puntos.
  &::before {
    position: absolute;
    top: 7px;
    right: 50%;
    left: -50%;
    height: 2px;
    background: var(--cu-gray-200);
    content: '';
  }

  &:first-child::before { display: none; }

  strong { font-size: 0.82rem; }
  small { color: var(--cu-muted); font-size: 0.72rem; }

  &[data-tone='accent'] { --dot: var(--cu-accent); }
  &[data-tone='dark'] { --dot: var(--cu-gray-800); }
  &[data-tone='due'] { --dot: var(--cu-accent-dark); }
}

.asf-timeline__dot {
  position: relative;
  z-index: 1;
  width: 16px;
  height: 16px;
  border: 3px solid var(--cu-surface);
  border-radius: 50%;
  background: var(--dot);
  box-shadow: 0 0 0 1px var(--cu-gray-300);
}

.asf-timeline__item[data-tone='due'] .asf-timeline__dot {
  width: 20px;
  height: 20px;
  margin-top: -2px;
}

// ── Acciones ─────────────────────────────────────────────────────────
.asf-actions {
  position: sticky;
  bottom: 0;
  z-index: 2;
  display: flex;
  flex-wrap: wrap;
  justify-content: flex-end;
  gap: 0.5rem;
  padding: 0.75rem 0;
  background: linear-gradient(to top, var(--cu-surface-alt) 70%, transparent);
}

@media (max-width: 1199.98px) {
  .asf-alerts { grid-template-columns: 1fr; }
}

@media (max-width: 767.98px) {
  .asf-card { padding: 1rem; }
  .asf-actions .btn { flex: 1 1 100%; }
}
```

> **Las tres alertas apiladas desde 1200 px:** cada una tiene ahora sus copias y el buscador, así que en tres columnas quedaban muy angostas.

---

## 7. Paso 6 — Estilos comunes de las dos páginas

### `presentation/_course-alerts-page.scss`

```scss
@use '../../../../styles/courses-tokens' as tokens;

:host {
  @include tokens.courses-tokens;
  display: block;
}

.cap {
  display: grid;
  gap: 1rem;
  max-width: 1100px;
  margin: 0 auto;
  padding: 1rem 0 2rem;
}

.cap__back {
  justify-self: start;
  display: inline-flex;
  align-items: center;
  gap: 0.45rem;
  color: var(--cu-muted);
  font-size: 0.875rem;
  font-weight: 600;
  text-decoration: none;

  &:hover { color: var(--cu-text); }
}

.cap__hero {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 1rem;
  padding: 1.25rem 1.5rem;
  border: 1px solid var(--cu-border);
  border-radius: var(--cu-radius-lg);
  background: linear-gradient(135deg, rgba(245, 197, 24, 0.1), rgba(245, 197, 24, 0.02));
}

.cap__icon {
  display: grid;
  flex-shrink: 0;
  width: 52px;
  height: 52px;
  place-items: center;
  border-radius: 12px;
  background: var(--cu-accent);
  color: var(--cu-on-accent);
  font-size: 1.35rem;
}

.cap__hero-text { flex: 1 1 18rem; min-width: 0; }

.cap__eyebrow {
  margin: 0;
  color: var(--cu-accent-text);
  font-size: 0.75rem;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
}

.cap__title { margin: 0.15rem 0 0; font-size: 1.5rem; font-weight: 700; }
.cap__subtitle { margin: 0.25rem 0 0; color: var(--cu-muted); font-size: 0.9rem; }

.cap__badge {
  padding: 0.25rem 0.75rem;
  border-radius: 999px;
  font-size: 0.78rem;
  font-weight: 700;

  &[data-tone='general'] { background: var(--cu-gray-100); color: var(--cu-gray-700); }
  &[data-tone='own'] { background: var(--cu-accent); color: var(--cu-on-accent); }
}

.cap__state {
  display: grid;
  justify-items: center;
  gap: 0.75rem;
  padding: 4rem 1rem;
  color: var(--cu-muted);
  text-align: center;

  .spinner-border { color: var(--cu-accent); }
}

.cap-card {
  padding: 1.25rem 1.5rem;
  border: 1px solid var(--cu-border);
  border-radius: var(--cu-radius-lg);
  background: var(--cu-surface);
  box-shadow: var(--cu-shadow-sm);
}

.cap-card__title { margin: 0 0 0.75rem; font-size: 1.05rem; font-weight: 700; }

.cap__meta { color: var(--cu-muted); font-size: 0.8rem; }

@media (max-width: 767.98px) {
  .cap__hero { padding: 1rem; }
  .cap-card { padding: 1rem; }
}
```

---

## 8. Paso 7 — Página general (`/cursos/alertas`)

`presentation/course-alerts-general-page/`

### `course-alerts-general.page.ts`

```ts
import { ChangeDetectionStrategy, Component, PLATFORM_ID, effect, inject, signal } from '@angular/core';
import { DatePipe, isPlatformServer } from '@angular/common';
import { RouterLink } from '@angular/router';
import { LayoutComponent } from '@core/layout/layout.component';
import { HeaderComponent } from '@shared/components/header/header.component';
import { UserInfoService } from '@core/services/user-info-msal.service';
import { GlobalPermissionsService } from '@core/services/global-permissions.service';
import { GlobalNotificationService } from '@shared/services/global-notification-alerts.service';
import { NotificationService } from '@shared/services/notification.service';
import { MenuPermission } from '@shared/entities/general/menu-permissions-service';
import { HasUnsavedChanges } from '@shared/guards/unsaved-changes.guard';
import { confirmDanger, initCourseFeedback, notifySuccess } from '@features/courses/course-feedback';
import { CourseAlertSettingsFacade } from '../../application/course-alert-settings.facade';
import { COURSE_ALERTS_INFRASTRUCTURE_PROVIDERS } from '../../infraestructure/course-alerts.providers';
import { ALERT_TYPE_LABEL, CourseAlertSettings } from '../../domain/course-alerts.model';
import { AlertSettingsFormComponent } from '../alert-settings-form/alert-settings-form.component';

@Component({
  selector: 'app-course-alerts-general-page',
  imports: [DatePipe, RouterLink, LayoutComponent, HeaderComponent, AlertSettingsFormComponent],
  providers: [...COURSE_ALERTS_INFRASTRUCTURE_PROVIDERS, CourseAlertSettingsFacade],
  templateUrl: './course-alerts-general.page.html',
  styleUrl: './course-alerts-general.page.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class CourseAlertsGeneralPage implements HasUnsavedChanges {
  protected readonly facade = inject(CourseAlertSettingsFacade);
  private readonly userInfoService = inject(UserInfoService);
  private readonly permissionsService = inject(GlobalPermissionsService);
  private readonly globalNotificationService = inject(GlobalNotificationService);
  private readonly platformId = inject(PLATFORM_ID);

  readonly typeLabel = ALERT_TYPE_LABEL;

  readonly permissions = signal<MenuPermission[]>([]);
  readonly userName = signal('');
  readonly userEmail = signal('');
  readonly userRole = signal('');
  readonly notificationCount = signal(0);

  /** Lo informa el formulario. */
  readonly dirty = signal(false);

  constructor() {
    initCourseFeedback(inject(NotificationService));

    if (isPlatformServer(this.platformId)) return;

    effect(() => {
      this.userInfoService.loadUserInfo().then(user => {
        if (!user?.mail) return;
        this.userEmail.set(user.mail);
        this.userName.set(user.displayName);
        this.userRole.set(user.jobTitle || '');
        this.globalNotificationService.refreshNotifications(user.mail);
        this.permissionsService.loadPermissions(user.mail).then(result => {
          if (!result.hasError) this.permissions.set(result.response);
        });
      });
    });

    effect(() => this.notificationCount.set(this.globalNotificationService.notificationCount()));

    void this.facade.loadGeneral();
  }

  hasUnsavedChanges(): boolean {
    return this.dirty();
  }

  async onSave(settings: CourseAlertSettings): Promise<void> {
    if (await this.facade.saveGeneral(settings)) {
      this.dirty.set(false);
      void this.facade.loadPreview(); // la vista previa cambia con la configuración
    }
  }

  async runNow(): Promise<void> {
    const ok = await confirmDanger(
      '¿Enviar las alertas de hoy?',
      'Los recordatorios, urgentes y reportes que tocan hoy quedan en cola y se envían en segundo plano. Lo que ya está en cola no se repite.',
      'Enviar ahora');
    if (!ok) return;

    const result = await this.facade.runNow();
    if (result) {
      notifySuccess(`En cola: ${result.reminders} recordatorios, ${result.urgent} urgentes y ${result.reports} reportes`);
    }
  }
}
```

### `course-alerts-general.page.html`

```html
<app-layout [permissions]="permissions()">
  <app-header
    [title]="'Módulo de Cursos'"
    [subText]="'Alertas por correo de los cursos'"
    [userName]="userName()"
    [userEmail]="userEmail()"
    [userRole]="userRole()"
    [notificationCount]="notificationCount()">
  </app-header>

  <section class="cap">
    <a routerLink="/cursos" class="cap__back"><i class="fa-solid fa-arrow-left" aria-hidden="true"></i> Volver a cursos</a>

    <header class="cap__hero">
      <span class="cap__icon"><i class="fa-solid fa-bell" aria-hidden="true"></i></span>
      <div class="cap__hero-text">
        <p class="cap__eyebrow">Configuración general</p>
        <h1 class="cap__title">Alertas de cursos</h1>
        <p class="cap__subtitle">Aplica a todos los cursos que no tengan una configuración propia.</p>
      </div>
      @if (facade.general()?.updatedBy; as by) {
        <span class="cap__meta">Última edición: {{ by }} · {{ facade.general()?.updatedDate | date: 'd MMM y, h:mm a' }}</span>
      }
    </header>

    @switch (facade.status()) {
      @case ('loading') {
        <div class="cap__state" role="status"><div class="spinner-border" aria-hidden="true"></div><p>Cargando configuración…</p></div>
      }
      @case ('error') {
        <div class="cap__state">
          <p>{{ facade.error() }}</p>
          <button type="button" class="btn btn-yellow btn-sm" (click)="facade.loadGeneral()">Reintentar</button>
        </div>
      }
      @default {
        @if (facade.general(); as general) {
          <app-alert-settings-form
            [value]="general"
            [saving]="facade.saving()"
            submitLabel="Guardar configuración general"
            (dirtyChange)="dirty.set($event)"
            (save)="onSave($event)" />
        }

        <!-- ── ¿Qué se enviaría hoy? ─────────────────────────────── -->
        <section class="cap-card cap-preview" aria-labelledby="cap-preview-title">
          <div class="cap-preview__head">
            <div>
              <h2 id="cap-preview-title" class="cap-card__title mb-1">¿Qué se enviaría hoy?</h2>
              <p class="cap__meta mb-0">Con la configuración guardada (la general y la de cada curso). No envía nada y no muestra lo que ya está en cola.</p>
            </div>
            <div class="cap-preview__actions">
              <button type="button" class="btn btn-outline-secondary" [disabled]="facade.previewLoading()" (click)="facade.loadPreview()">
                <i class="fa-solid fa-eye me-1" aria-hidden="true"></i> Ver vista previa
              </button>
              <button type="button" class="btn btn-yellow" [disabled]="facade.previewLoading()" (click)="runNow()">
                <i class="fa-solid fa-paper-plane me-1" aria-hidden="true"></i> Enviar ahora
              </button>
            </div>
          </div>

          @if (facade.previewLoading()) {
            <div class="cap__state py-4" role="status"><div class="spinner-border" aria-hidden="true"></div></div>
          } @else if (facade.preview(); as preview) {
            <div class="cap-preview__counts">
              <span class="cap-count" data-tone="accent">{{ preview.reminders }} recordatorios</span>
              <span class="cap-count" data-tone="dark">{{ preview.urgent }} urgentes</span>
              <span class="cap-count">{{ preview.reports }} reportes</span>
            </div>

            @if (preview.items.length) {
              <div class="cap-table-wrap">
                <table class="cap-table">
                  <caption class="visually-hidden">Correos que se enviarían hoy</caption>
                  <thead>
                    <tr><th scope="col">Tipo</th><th scope="col">Curso · grupo</th><th scope="col">Vence</th><th scope="col">Para</th><th scope="col">Copias</th></tr>
                  </thead>
                  <tbody>
                    @for (item of preview.items; track $index) {
                      <tr>
                        <td data-label="Tipo"><span class="cap-type" [attr.data-type]="item.alertType">{{ typeLabel[item.alertType] }}</span></td>
                        <td data-label="Curso · grupo"><strong class="d-block">{{ item.courseName }}</strong><small>{{ item.groupName }}</small></td>
                        <td data-label="Vence" class="text-nowrap">{{ item.dueDate | date: 'd MMM y' }}</td>
                        <td data-label="Para">{{ item.to }}</td>
                        <td data-label="Copias"><small>{{ item.copies.length ? item.copies.join(', ') : '—' }}</small></td>
                      </tr>
                    }
                  </tbody>
                </table>
              </div>
            } @else {
              <p class="cap__meta mt-2 mb-0">Hoy no hay alertas por enviar.</p>
            }
          }
        </section>
      }
    }
  </section>
</app-layout>
```

### `course-alerts-general.page.scss`

```scss
@use '../course-alerts-page';

.cap-preview__head {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-start;
  justify-content: space-between;
  gap: 0.75rem;
  margin-bottom: 0.75rem;
}

.cap-preview__actions { display: flex; flex-wrap: wrap; gap: 0.5rem; }

.cap-preview__counts { display: flex; flex-wrap: wrap; gap: 0.5rem; margin-bottom: 0.75rem; }

.cap-count {
  padding: 0.2rem 0.7rem;
  border-radius: 999px;
  background: var(--cu-gray-100);
  color: var(--cu-gray-700);
  font-size: 0.8rem;
  font-weight: 700;

  &[data-tone='accent'] { background: var(--cu-accent-subtle-bg); color: var(--cu-accent-text); }
  &[data-tone='dark'] { background: var(--cu-gray-800); color: #fff; }
}

.cap-table-wrap {
  overflow-x: auto;
  border: 1px solid var(--cu-border);
  border-radius: var(--cu-radius-sm);
}

.cap-table {
  width: 100%;
  font-size: 0.85rem;

  th {
    padding: 0.6rem 0.8rem;
    background: var(--cu-gray-50);
    color: var(--cu-muted);
    font-size: 0.72rem;
    font-weight: 700;
    text-transform: uppercase;
  }

  td {
    padding: 0.55rem 0.8rem;
    border-top: 1px solid var(--cu-border);
    vertical-align: top;
  }
}

.cap-type {
  padding: 0.1rem 0.55rem;
  border-radius: 999px;
  background: var(--cu-gray-100);
  color: var(--cu-gray-700);
  font-size: 0.72rem;
  font-weight: 700;
  white-space: nowrap;

  &[data-type='COURSE_DUE_REMINDER'] { background: var(--cu-accent); color: var(--cu-on-accent); }
  &[data-type='COURSE_DUE_URGENT'] { background: var(--cu-gray-800); color: #fff; }
}

@media (max-width: 767.98px) {
  .cap-table thead { display: none; }
  .cap-table tr { display: block; padding: 0.5rem 0.75rem; border-top: 1px solid var(--cu-border); }
  .cap-table td { display: flex; justify-content: space-between; gap: 1rem; padding: 0.2rem 0; border: 0; text-align: right; }
  .cap-table td::before { content: attr(data-label); color: var(--cu-muted); font-size: 0.75rem; font-weight: 600; text-align: left; }
}
```

---

## 9. Paso 8 — Página de un curso (`/cursos/:id/alertas`)

`presentation/course-alerts-course-page/`

### `course-alerts-course.page.ts`

```ts
import { ChangeDetectionStrategy, Component, PLATFORM_ID, computed, effect, inject, signal, untracked } from '@angular/core';
import { DatePipe, isPlatformServer } from '@angular/common';
import { ActivatedRoute, RouterLink } from '@angular/router';
import { toSignal } from '@angular/core/rxjs-interop';
import { map } from 'rxjs';
import { LayoutComponent } from '@core/layout/layout.component';
import { HeaderComponent } from '@shared/components/header/header.component';
import { UserInfoService } from '@core/services/user-info-msal.service';
import { GlobalPermissionsService } from '@core/services/global-permissions.service';
import { GlobalNotificationService } from '@shared/services/global-notification-alerts.service';
import { NotificationService } from '@shared/services/notification.service';
import { MenuPermission } from '@shared/entities/general/menu-permissions-service';
import { HasUnsavedChanges } from '@shared/guards/unsaved-changes.guard';
import { confirmDanger, initCourseFeedback } from '@features/courses/course-feedback';
import { CourseAlertSettingsFacade } from '../../application/course-alert-settings.facade';
import { COURSE_ALERTS_INFRASTRUCTURE_PROVIDERS } from '../../infraestructure/course-alerts.providers';
import { CourseAlertSettings, describeSettings } from '../../domain/course-alerts.model';
import { AlertSettingsFormComponent } from '../alert-settings-form/alert-settings-form.component';

@Component({
  selector: 'app-course-alerts-course-page',
  imports: [DatePipe, RouterLink, LayoutComponent, HeaderComponent, AlertSettingsFormComponent],
  providers: [...COURSE_ALERTS_INFRASTRUCTURE_PROVIDERS, CourseAlertSettingsFacade],
  templateUrl: './course-alerts-course.page.html',
  styleUrl: './course-alerts-course.page.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class CourseAlertsCoursePage implements HasUnsavedChanges {
  protected readonly facade = inject(CourseAlertSettingsFacade);
  private readonly route = inject(ActivatedRoute);
  private readonly userInfoService = inject(UserInfoService);
  private readonly permissionsService = inject(GlobalPermissionsService);
  private readonly globalNotificationService = inject(GlobalNotificationService);
  private readonly platformId = inject(PLATFORM_ID);

  readonly permissions = signal<MenuPermission[]>([]);
  readonly userName = signal('');
  readonly userEmail = signal('');
  readonly userRole = signal('');
  readonly notificationCount = signal(0);

  readonly courseId = toSignal(this.route.paramMap.pipe(map(params => Number(params.get('id')) || null)), { initialValue: null });

  /** Usa la general y se está armando una propia (el formulario arranca con los valores de la general). */
  readonly customizing = signal(false);
  readonly dirty = signal(false);

  readonly showForm = computed(() => {
    const course = this.facade.course();
    return !!course && (!course.usesGeneral || this.customizing());
  });

  readonly summary = computed(() => {
    const course = this.facade.course();
    return course ? describeSettings(course.settings) : [];
  });

  constructor() {
    initCourseFeedback(inject(NotificationService));

    if (isPlatformServer(this.platformId)) return;

    effect(() => {
      this.userInfoService.loadUserInfo().then(user => {
        if (!user?.mail) return;
        this.userEmail.set(user.mail);
        this.userName.set(user.displayName);
        this.userRole.set(user.jobTitle || '');
        this.globalNotificationService.refreshNotifications(user.mail);
        this.permissionsService.loadPermissions(user.mail).then(result => {
          if (!result.hasError) this.permissions.set(result.response);
        });
      });
    });

    effect(() => this.notificationCount.set(this.globalNotificationService.notificationCount()));

    effect(() => {
      const id = this.courseId();
      if (!id) return;
      untracked(() => {
        this.customizing.set(false);
        void this.facade.loadCourse(id);
      });
    });
  }

  hasUnsavedChanges(): boolean {
    return this.dirty();
  }

  cancelCustomizing(): void {
    this.customizing.set(false);
    this.dirty.set(false);
  }

  async onSave(settings: CourseAlertSettings): Promise<void> {
    const id = this.courseId();
    if (id && (await this.facade.saveCourse(id, settings))) {
      this.customizing.set(false);
      this.dirty.set(false);
    }
  }

  async resetToGeneral(): Promise<void> {
    const id = this.courseId();
    if (!id) return;

    const ok = await confirmDanger(
      '¿Volver a la configuración general?',
      'Se borra la configuración propia de este curso y desde ahora aplica la general.',
      'Volver a la general');
    if (ok && (await this.facade.resetCourse(id))) {
      this.dirty.set(false);
    }
  }
}
```

### `course-alerts-course.page.html`

```html
<app-layout [permissions]="permissions()">
  <app-header
    [title]="'Módulo de Cursos'"
    [subText]="'Alertas por correo de este curso'"
    [userName]="userName()"
    [userEmail]="userEmail()"
    [userRole]="userRole()"
    [notificationCount]="notificationCount()">
  </app-header>

  <section class="cap">
    <a routerLink="/cursos" class="cap__back"><i class="fa-solid fa-arrow-left" aria-hidden="true"></i> Volver a cursos</a>

    @if (!courseId()) {
      <div class="cap__state"><p>El curso no es válido.</p><a routerLink="/cursos" class="btn btn-yellow btn-sm">Ir a cursos</a></div>
    } @else {
      @switch (facade.status()) {
        @case ('loading') {
          <div class="cap__state" role="status"><div class="spinner-border" aria-hidden="true"></div><p>Cargando…</p></div>
        }
        @case ('error') {
          <div class="cap__state">
            <p>{{ facade.error() }}</p>
            <button type="button" class="btn btn-yellow btn-sm" (click)="facade.loadCourse(courseId()!)">Reintentar</button>
          </div>
        }
        @default {
          @if (facade.course(); as course) {
            <header class="cap__hero">
              <span class="cap__icon"><i class="fa-solid fa-bell" aria-hidden="true"></i></span>
              <div class="cap__hero-text">
                <p class="cap__eyebrow">Alertas del curso</p>
                <h1 class="cap__title">{{ course.courseName }}</h1>
                <p class="cap__subtitle">
                  @if (course.usesGeneral) {
                    Usa la configuración general. Si la personalizas, la de este curso manda.
                  } @else {
                    Tiene configuración propia: la general no aplica a este curso.
                  }
                </p>
              </div>
              <span class="cap__badge" [attr.data-tone]="course.usesGeneral ? 'general' : 'own'">
                {{ course.usesGeneral ? 'Configuración general' : 'Configuración propia' }}
              </span>
            </header>

            @if (showForm()) {
              <app-alert-settings-form
                [value]="course.settings"
                [saving]="facade.saving()"
                submitLabel="Guardar configuración del curso"
                (dirtyChange)="dirty.set($event)"
                (save)="onSave($event)">
                <div asfExtraActions class="d-flex flex-wrap gap-2 me-auto">
                  @if (course.usesGeneral) {
                    <button type="button" class="btn btn-outline-secondary" (click)="cancelCustomizing()">Cancelar</button>
                  } @else {
                    <button type="button" class="btn btn-outline-secondary" [disabled]="facade.saving()" (click)="resetToGeneral()">
                      <i class="fa-solid fa-rotate-left me-1" aria-hidden="true"></i> Volver a la configuración general
                    </button>
                  }
                </div>
              </app-alert-settings-form>
            } @else {
              <section class="cap-card" aria-labelledby="cap-summary-title">
                <h2 id="cap-summary-title" class="cap-card__title">Lo que aplica hoy (configuración general)</h2>
                <dl class="cap-summary">
                  @for (row of summary(); track row.label) {
                    <div class="cap-summary__row"><dt>{{ row.label }}</dt><dd>{{ row.value }}</dd></div>
                  }
                </dl>
                <div class="cap-summary__actions">
                  <a routerLink="/cursos/alertas" class="btn btn-outline-secondary">Editar la configuración general</a>
                  <button type="button" class="btn btn-yellow" (click)="customizing.set(true)">
                    <i class="fa-solid fa-sliders me-1" aria-hidden="true"></i> Personalizar para este curso
                  </button>
                </div>
              </section>
            }

            <a class="cap__back" [routerLink]="['/cursos', course.courseId, 'resultados']">
              <i class="fa-solid fa-chart-column" aria-hidden="true"></i> Ver resultados del curso
            </a>
          }
        }
      }
    }
  </section>
</app-layout>
```

### `course-alerts-course.page.scss`

```scss
@use '../course-alerts-page';

.cap-summary {
  display: grid;
  gap: 0;
  margin: 0 0 1rem;
}

.cap-summary__row {
  display: grid;
  grid-template-columns: 12rem 1fr;
  gap: 1rem;
  padding: 0.55rem 0;
  border-top: 1px solid var(--cu-border);

  &:first-child { border-top: 0; }

  dt { color: var(--cu-muted); font-size: 0.85rem; font-weight: 600; }
  dd { margin: 0; font-size: 0.9rem; }
}

.cap-summary__actions {
  display: flex;
  flex-wrap: wrap;
  justify-content: flex-end;
  gap: 0.5rem;
}

@media (max-width: 767.98px) {
  .cap-summary__row { grid-template-columns: 1fr; gap: 0.15rem; }
  .cap-summary__actions .btn { flex: 1 1 100%; }
}
```

---

## 10. Paso 9 — Rutas y accesos

### `app.routes.ts` ✏️ — después de `cursos`

```ts
{
  path: 'cursos/alertas',
  canDeactivate: [unsavedChangesGuard],
  loadComponent: () =>
    import('@features/course-alerts/presentation/course-alerts-general-page/course-alerts-general.page')
      .then(m => m.CourseAlertsGeneralPage),
},
{
  path: 'cursos/:id/alertas',
  canDeactivate: [unsavedChangesGuard],
  loadComponent: () =>
    import('@features/course-alerts/presentation/course-alerts-course-page/course-alerts-course.page')
      .then(m => m.CourseAlertsCoursePage),
},
```

> `cursos/alertas` (2 segmentos) y `cursos/:id/alertas` (3) no chocan entre sí ni con `cursos/:id/resultados`.

### `courses.page.html` ✏️ — reemplaza el botón "Nuevo curso" del encabezado por este bloque (los dos botones juntos)

```html
<div class="d-flex flex-wrap gap-2">
  <a routerLink="/cursos/alertas" class="btn btn-outline-secondary shadow-sm">
    <i class="fa-solid fa-bell me-2" aria-hidden="true"></i>Configurar alertas
  </a>
  <button type="button" class="btn btn-warning courses-hero__cta shadow-sm" (click)="facade.openCreate()">
    <i class="fa-solid fa-plus me-2" aria-hidden="true"></i>Nuevo curso
  </button>
</div>
```

Y en la tarjeta de cada curso:

```html
(configureAlerts)="configureAlerts(course)"
```

### `courses.page.ts` ✏️

Agrega `RouterLink` a `imports`. `Router` ya está si aplicaste la guía de resultados como página; si no, inyéctalo.

```ts
configureAlerts(course: CourseSummary): void {
  void this.router.navigate(['/cursos', course.id, 'alertas']);
}
```

### `course-card.component.ts` ✏️

```ts
readonly configureAlerts = output<void>();
```

### `course-card.component.html` ✏️ — en `.course-card__actions`, antes de "Editar"

```html
<button
  type="button"
  class="action-btn action-btn--alerts"
  [attr.aria-label]="'Alertas de ' + course().name"
  title="Alertas por correo"
  (click)="configureAlerts.emit()">
  <i class="fa-solid fa-bell" aria-hidden="true"></i>
</button>
```

En `course-card.component.scss`, si los `action-btn--*` tienen color propio al pasar el mouse:

```scss
.action-btn--alerts:hover {
  background: #f5c518;
  color: #111827;
}
```

### `course-results.page.html` ✏️ — en el encabezado, junto a "Actualizar"

```html
<a class="btn btn-outline-secondary" [routerLink]="['/cursos', courseId(), 'alertas']">
  <i class="fa-solid fa-bell me-1" aria-hidden="true"></i> Alertas
</a>
```

### `email-logs/domain/email-log.model.ts` ✏️ — los dos tipos nuevos en `ALERT_TYPE_LABELS`

La API agrega `COURSE_DUE_URGENT` y `COURSE_RESULTS_REPORT` a `EmailAlertTypes.All`, así que salen en el filtro de "Registro de correos". Sin esto se ven con el código:

```ts
const ALERT_TYPE_LABELS: Readonly<Record<string, string>> = {
  COURSE_ASSIGNED: 'Curso asignado',
  COURSE_DUE_REMINDER: 'Recordatorio de curso',
  COURSE_DUE_URGENT: 'Alerta urgente de curso',
  COURSE_OVERDUE: 'Curso vencido',
  COURSE_RESULTS_REPORT: 'Reporte de resultados de curso',
  REQUEST_SHARED: 'Solicitud compartida',
};
```

---

## 11. Pruebas

**Configuración general (`/cursos/alertas`)**
- **Abrirla:**
  - Desde "Configurar alertas" en Cursos.
  - Carga con los valores por defecto: bienvenida sin copias, recordatorio 7 días antes y urgente 2 días antes con copia a su líder.
- **Copias por alerta:**
  - Cada alerta encendida muestra "Con copia a" con su líder, su gerencia, su dirección y "Otras personas en copia".
  - Marcar el líder en el recordatorio no lo marca en la urgente.
- **Gerencia y dirección:** tienen la etiqueta "Pronto" y, al marcarlas, el aviso de que aún no se envían.
- **Buscar personas:**
  - Escribir "ana" muestra personas de `/api/users/search` con nombre y correo, y elegir una la agrega como chip.
  - Escribir `formacion@empresa.co` (que no está en usuarios) ofrece "Agregar «formacion@empresa.co»".
  - Pegar `Ana <ana@x.co>; b@x.co, ana@x.co` agrega dos chips.
  - La × quita uno. Backspace con el buscador vacío quita el último.
- **Días como número libre:**
  - Recordatorio en 45 y urgente en 10 se aceptan.
  - 400 o 2,5 muestran "Un número entero de 0 a 365.".
  - El texto de ayuda dice "45 días antes".
- **Momentos del reporte:**
  - "10" + "días antes" + Agregar crea el chip "10 días antes".
  - "el día de la fecha límite" no pide número.
  - Agregar uno repetido dice "… ya está en la lista.".
  - El máximo es 20.
- **Avisos antes de guardar:**
  - **Urgente 7 días y recordatorio 3:** "La alerta urgente debe enviarse más cerca…".
  - **Reporte activo sin momentos o sin destinatarios:** sus dos avisos. No se envía a la API.
- **Línea de tiempo:** se mueve al cambiar los días. Por ejemplo: Asignación → Recordatorio (45 días antes) → Urgente (10 días antes) → Fecha límite → Reporte (3 días después).
- **Guardar:** el aviso "Configuración general guardada" y "Última edición: tu correo · fecha".
- **Salir sin guardar:** con cambios pendientes, "¿Salir sin guardar?". Después de guardar, sale sin preguntar.
- **Vista previa:**
  - "Ver vista previa" muestra los conteos y la tabla, con el tipo en amarillo (recordatorio), gris oscuro (urgente) o gris (reporte).
  - Las copias aparecen como "Líder", "Gerencia" y los correos de cada alerta, y los reportes a líderes como "correo (líder: su equipo)".
  - Sin nada pendiente: "Hoy no hay alertas por enviar".
- **"Enviar ahora":** pide confirmación, responde enseguida con "En cola: …" y la vista previa queda vacía. Repetirlo encola 0.
  - El avance se ve en Cursos: el indicador de la tarjeta y el modal "Envío de correos" ([cursos-cola-correos-angular.md](cursos-cola-correos-angular.md)).
- **"Registro de correos":** el filtro de tipo muestra "Alerta urgente de curso" y "Reporte de resultados de curso".

**Un curso (`/cursos/:id/alertas`)**
- **Abrirla:** desde la campana de la tarjeta (o "Alertas" en Resultados).
- **Curso sin configuración propia:** la etiqueta "Configuración general", el resumen y "Personalizar para este curso".
- **Personalizar:** el formulario arranca con los valores de la general.
  - "Cancelar" vuelve al resumen.
  - "Guardar" cambia la etiqueta a "Configuración propia" (amarilla).
- **"Volver a la configuración general":** pide confirmación, borra la propia y vuelve al resumen.
- **Curso inexistente:** el mensaje de la API ("El curso no existe.") con "Reintentar".

**Colores:** solo amarillos y grises en las dos páginas (alertas, chips, etiquetas, línea de tiempo y tabla).

---

## ✅ Checklist

- [ ] `features/course-alerts/domain`: modelo y repositorio.
- [ ] `infraestructure`: servicio y providers (con `UsersDirectoryRepository`).
- [ ] `application`: `CourseAlertSettingsFacade`.
- [ ] `presentation`:
  - `_course-alerts-page.scss`.
  - `email-picker` (buscador de `/api/users/search`) y `alert-recipients`.
  - `alert-settings-form`.
  - Las dos páginas.
- [ ] Rutas `cursos/alertas` y `cursos/:id/alertas` con `unsavedChangesGuard`.
- [ ] Accesos:
  - "Configurar alertas" en Cursos.
  - La campana en la tarjeta.
  - "Alertas" en Resultados.
- [ ] `ALERT_TYPE_LABELS`: `COURSE_DUE_URGENT` y `COURSE_RESULTS_REPORT`.

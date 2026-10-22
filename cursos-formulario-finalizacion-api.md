# 📝 Cursos — Formulario de finalización con 5 preguntas — API (.NET 8) y SQL Server

**Lo que cambia:** el formulario que la persona llena al finalizar un curso pasa de 2 a 5 preguntas, y cada curso decide cuáles son obligatorias.

| # | Pregunta | Respuesta | Si no es obligatoria |
|---|---|---|---|
| 1 | ¿Cómo calificas la calidad del espacio de formación (contenido, recursos de aprendizaje, metodologías)? | 0 a 5 estrellas | Queda en **0 = sin calificar** |
| 2 | ¿Qué tan útil consideras que fue la información recibida para tu rol o tus funciones? | 0 a 5 estrellas | Queda en **0 = sin calificar** |
| 3 | En una escala de 1 a 10, ¿qué nivel de conocimiento tenías sobre las temáticas antes de esta capacitación? | 1 a 10 | Sin respuesta |
| 4 | En una escala de 1 a 10, ¿qué nivel de conocimiento consideras que tienes después de la capacitación? | 1 a 10 | Sin respuesta |
| 5 | Comentarios | Texto libre (hasta 1.000 caracteres) | Vacío |

**Preguntas obligatorias por curso:** en el editor del curso se marcan una, varias, todas o ninguna. Si una es obligatoria:
- Las estrellas deben ir de 1 a 5.
- La escala debe tener un valor.
- Los comentarios no pueden ir vacíos.

**Las respuestas siguen siendo anónimas:** van a `course_rating`, que no tiene ninguna relación con la persona.

**El frontend** está en [cursos-formulario-finalizacion-angular.md](cursos-formulario-finalizacion-angular.md). **Base:** el código de la rama de cursos (`.claude/Cursos API`).

---

## 1. Decisiones

| # | Tema | Decisión |
|---|---|---|
| 1 | **Dónde se guardan las respuestas.** | En `course_rating`, la misma tabla anónima: tres columnas nuevas (`knowledge_before`, `knowledge_after`, `comments`). |
| 2 | **El 0 de las estrellas.** | Pasa a significar **"sin calificar"**. Los promedios se calculan solo con 1 a 5, y el resumen cuenta aparte cuántos no calificaron. ⚠️ Las calificaciones de 0 que ya existen en la base cuentan desde ahora como "sin calificar". |
| 3 | **Nombres en el código.** | `Satisfaction` y `Usefulness` se quedan como nombres de columna y propiedad (`Satisfaction` ahora guarda la calidad del espacio de formación). Así no se renombra lo que ya usan el reporte y la página de resultados. |
| 4 | **Dónde se configuran las obligatorias.** | En el curso: columna `course.completion_required_questions` (lista JSON de códigos), que se edita en el editor del curso. |
| 5 | **Editar un curso desde otras pantallas.** | "Agregar grupo" y "Cambiar fecha" mandan el curso completo sin las preguntas. `RequiredQuestions` en `null` significa "no cambiar", así no las borran. |
| 6 | **Comentarios en los resultados.** | Solo a nivel de curso (nunca por grupo) y solo con el mínimo de respuestas del anonimato. Se muestran los 50 más recientes, sin fecha ni nombre. |

**Códigos de las preguntas:** `QUALITY`, `USEFULNESS`, `KNOWLEDGE_BEFORE`, `KNOWLEDGE_AFTER`, `COMMENTS`.

---

## 2. Archivos

```text
DOCCB.Domain/Entities/
├── Course.cs                                                  ✏️ + CompletionRequiredQuestions
└── CourseRating.cs                                            ✏️ + KnowledgeBefore, KnowledgeAfter, Comments

DOCCB.Application/
├── Contracts/Persistence/ICourseCompletionRepository.cs       ✏️ RatingBucket + 2 métodos
├── Features/Courses/Application/
│   ├── Constants/CompletionConstants.cs                       ✏️ límites y mensajes
│   ├── Constants/CompletionQuestions.cs                       nuevo
│   ├── DTOs/CompletionDtos.cs                                 ✏️ formulario y respuestas
│   ├── DTOs/CourseProgressDtos.cs                             ✏️ RatingSummaryDto
│   ├── DTOs/SaveCourseRequestDto.cs                           ✏️ + RequiredQuestions
│   ├── DTOs/(CourseDetailDto)                                 ✏️ + RequiredQuestions
│   ├── Helpers/CourseValidationHelper.cs                      ✏️ valida los códigos
│   ├── Helpers/CompletionAnswersValidator.cs                  nuevo
│   ├── Helpers/RatingSummaryBuilder.cs                        ✏️ promedios sin el 0
│   ├── Services/CourseCompletionService.cs                    ✏️
│   └── Services/CourseService.cs                              ✏️ guarda las obligatorias

DOCCB.Infraestructure/
├── Configurations/CourseConfiguration.cs                      ✏️
├── Configurations/CourseRatingConfiguration.cs                ✏️
├── Repositories/CourseCompletionRepository.cs                 ✏️
├── Repositories/CourseRepository.cs                           ✏️ detalle
└── Persistence/Scripts SQL/CursosFormularioPreguntas.sql      nuevo
```

---

## 3. Paso 1 — 🗄️ Base de datos

### `Persistence/Scripts SQL/CursosFormularioPreguntas.sql`

```sql
/* =====================================================================
   Cursos · formulario de finalización con 5 preguntas
   Base de datos: DB · Esquema: dbo

   REQUIERE:
   - dbo.course
   - dbo.course_rating

   CREA:
   - course.completion_required_questions (JSON con los códigos obligatorios)
   - course_rating.knowledge_before, knowledge_after, comments

   El script se puede ejecutar varias veces: solo crea lo que no existe.
   ===================================================================== */
USE [DB];
GO

-- Preguntas obligatorias de cada curso. [] = ninguna.
IF COL_LENGTH('dbo.course', 'completion_required_questions') IS NULL
    ALTER TABLE dbo.course
        ADD completion_required_questions NVARCHAR(200) NOT NULL
            CONSTRAINT df_course_completion_required_questions DEFAULT (N'[]') WITH VALUES;
GO

-- Pregunta 3: conocimiento antes (1 a 10). NULL = sin responder.
IF COL_LENGTH('dbo.course_rating', 'knowledge_before') IS NULL
    ALTER TABLE dbo.course_rating
        ADD knowledge_before TINYINT NULL
            CONSTRAINT ck_course_rating_knowledge_before CHECK (knowledge_before BETWEEN 1 AND 10);
GO

-- Pregunta 4: conocimiento después (1 a 10). NULL = sin responder.
IF COL_LENGTH('dbo.course_rating', 'knowledge_after') IS NULL
    ALTER TABLE dbo.course_rating
        ADD knowledge_after TINYINT NULL
            CONSTRAINT ck_course_rating_knowledge_after CHECK (knowledge_after BETWEEN 1 AND 10);
GO

-- Pregunta 5: comentarios. Anónimos, como el resto de la fila.
IF COL_LENGTH('dbo.course_rating', 'comments') IS NULL
    ALTER TABLE dbo.course_rating ADD comments NVARCHAR(1000) NULL;
GO
```

> `satisfaction` y `usefulness` siguen igual (0 a 5). Lo que cambia es que el 0 ahora significa "sin calificar".

---

## 4. Paso 2 — Dominio y EF Core

### `Course.cs` ✏️ — agrega

```csharp
/// <summary>Preguntas obligatorias del formulario de finalización (CompletionQuestions). Vacía = todas opcionales.</summary>
public List<string> CompletionRequiredQuestions { get; set; } = [];
```

### `CourseRating.cs` ✏️ — agrega

```csharp
/// <summary>Pregunta 3: conocimiento antes de la capacitación (1 a 10). null = sin responder.</summary>
public byte? KnowledgeBefore { get; set; }

/// <summary>Pregunta 4: conocimiento después de la capacitación (1 a 10). null = sin responder.</summary>
public byte? KnowledgeAfter { get; set; }

/// <summary>Pregunta 5. Anónimo como el resto de la fila.</summary>
public string? Comments { get; set; }
```

Y actualiza el comentario de las dos que ya están:

```csharp
/// <summary>Pregunta 1: calidad del espacio de formación (1 a 5). 0 = sin calificar.</summary>
public byte Satisfaction { get; set; }

/// <summary>Pregunta 2: utilidad para el rol o las funciones (1 a 5). 0 = sin calificar.</summary>
public byte Usefulness { get; set; }
```

### `CourseConfiguration.cs` ✏️ — agrega

```csharp
// EF Core 8: List<string> se guarda como JSON en nvarchar.
builder.Property(c => c.CompletionRequiredQuestions)
    .HasColumnName("completion_required_questions")
    .HasMaxLength(200);
```

### `CourseRatingConfiguration.cs` ✏️

En el `ToTable(…, table => { … })`, junto a los dos `HasCheckConstraint` que ya hay:

```csharp
table.HasCheckConstraint("ck_course_rating_knowledge_before", "knowledge_before BETWEEN 1 AND 10");
table.HasCheckConstraint("ck_course_rating_knowledge_after", "knowledge_after BETWEEN 1 AND 10");
```

Y las propiedades:

```csharp
builder.Property(r => r.KnowledgeBefore).HasColumnName("knowledge_before");
builder.Property(r => r.KnowledgeAfter).HasColumnName("knowledge_after");
builder.Property(r => r.Comments).HasColumnName("comments").HasMaxLength(1000);
```

---

## 5. Paso 3 — Constantes y DTOs

### `Constants/CompletionQuestions.cs`

```csharp
namespace DOCCB.Application.Features.Courses.Application.Constants
{
    /// <summary>Códigos de las 5 preguntas del formulario de finalización.</summary>
    public static class CompletionQuestions
    {
        public const string Quality = "QUALITY";
        public const string Usefulness = "USEFULNESS";
        public const string KnowledgeBefore = "KNOWLEDGE_BEFORE";
        public const string KnowledgeAfter = "KNOWLEDGE_AFTER";
        public const string Comments = "COMMENTS";

        public static readonly string[] All = [Quality, Usefulness, KnowledgeBefore, KnowledgeAfter, Comments];
    }
}
```

### `Constants/CompletionConstants.cs` ✏️

Reemplaza `RatingsRequired` por estos (y deja lo demás igual):

```csharp
public const int MinKnowledge = 1;
public const int MaxKnowledge = 10;
public const int CommentsMaxLength = 1000;
/// <summary>Comentarios que se muestran en los resultados del curso.</summary>
public const int CommentsLimit = 50;

public const string QualityRequired = "Califica la calidad del espacio de formación (de 1 a 5 estrellas).";
public const string UsefulnessRequired = "Califica qué tan útil fue la información para tu rol (de 1 a 5 estrellas).";
public const string KnowledgeBeforeRequired = "Elige tu nivel de conocimiento antes de la capacitación (de 1 a 10).";
public const string KnowledgeAfterRequired = "Elige tu nivel de conocimiento después de la capacitación (de 1 a 10).";
public const string CommentsRequired = "Escribe tus comentarios.";
public const string StarsOutOfRange = "Las calificaciones van de 0 a 5 estrellas.";
public const string KnowledgeOutOfRange = "El nivel de conocimiento va de 1 a 10.";
public const string CommentsTooLong = "Los comentarios pueden tener hasta 1.000 caracteres.";
public const string UnknownQuestion = "Pregunta desconocida: {0}.";
```

### `DTOs/CompletionDtos.cs` ✏️

**1. En `CompletionFormDto`**, agrega:

```csharp
/// <summary>Códigos de las preguntas obligatorias de este curso (CompletionQuestions).</summary>
public List<string> RequiredQuestions { get; set; } = [];
```

**2. `CompleteCourseRequestDto`** queda así:

```csharp
/// <summary>Las respuestas del formulario. Ni la gerencia ni la fecha: esas las pone el servidor.</summary>
public class CompleteCourseRequestDto
{
    /// <summary>Pregunta 1, de 0 a 5. 0 o null = sin calificar.</summary>
    public int? Satisfaction { get; set; }
    /// <summary>Pregunta 2, de 0 a 5. 0 o null = sin calificar.</summary>
    public int? Usefulness { get; set; }
    /// <summary>Pregunta 3, de 1 a 10. null = sin responder.</summary>
    public int? KnowledgeBefore { get; set; }
    /// <summary>Pregunta 4, de 1 a 10. null = sin responder.</summary>
    public int? KnowledgeAfter { get; set; }
    /// <summary>Pregunta 5.</summary>
    public string? Comments { get; set; }
}
```

### `DTOs/CourseProgressDtos.cs` ✏️ — en `RatingSummaryDto`

```csharp
/// <summary>Índice = estrellas (0 a 5). El índice 0 cuenta a quienes no calificaron.</summary>
public int[]? SatisfactionDistribution { get; set; }
public int[]? UsefulnessDistribution { get; set; }

public double? KnowledgeBeforeAverage { get; set; }
public double? KnowledgeAfterAverage { get; set; }
/// <summary>Índice = nivel (1 a 10). El índice 0 cuenta a quienes no respondieron.</summary>
public int[]? KnowledgeBeforeDistribution { get; set; }
public int[]? KnowledgeAfterDistribution { get; set; }

/// <summary>Solo en el resumen del curso y con el mínimo de respuestas. Los más recientes, sin fecha ni nombre.</summary>
public List<string>? Comments { get; set; }
```

(Reemplaza el comentario "Índice = calificación (0 a 5)" de las dos distribuciones que ya existen.)

### `DTOs/SaveCourseRequestDto.cs` ✏️ — en `SaveCourseRequestDto`

```csharp
/// <summary>
/// Códigos de las preguntas obligatorias del formulario (CompletionQuestions).
/// null = no cambiar (las pantallas de "Agregar grupo" y "Cambiar fecha" no las envían).
/// </summary>
public List<string>? RequiredQuestions { get; set; }
```

### `CourseDetailDto` ✏️ — agrega

```csharp
public List<string> RequiredQuestions { get; set; } = [];
```

---

## 6. Paso 4 — Guardar las obligatorias en el curso

### `Helpers/CourseValidationHelper.cs` ✏️

**1. El borrador** lleva las preguntas:

```csharp
public sealed record CourseDraft(
    string Name, string? ExternalId, string? Url,
    IReadOnlyList<AssignmentDraft> Assignments,
    IReadOnlyList<string>? RequiredQuestions);
```

**2. En `Normalize`**, antes del `return`:

```csharp
// null = no cambiar. Si viene, solo códigos conocidos y sin repetir.
List<string>? requiredQuestions = null;
if (dto.RequiredQuestions is not null)
{
    requiredQuestions = dto.RequiredQuestions
        .Select(code => code?.Trim().ToUpperInvariant() ?? string.Empty)
        .Where(code => code.Length > 0)
        .Distinct()
        .ToList();

    foreach (var unknown in requiredQuestions.Where(code => !CompletionQuestions.All.Contains(code)))
        errors.Add(string.Format(CompletionConstants.UnknownQuestion, unknown));
}
```

Y el `return`:

```csharp
return errors.Count > 0
    ? (null, errors)
    : (new CourseDraft(name, externalId, url, assignments, requiredQuestions), errors);
```

### `Services/CourseService.cs` ✏️

**`CreateAsync`**, en el `new Course { … }`:

```csharp
CompletionRequiredQuestions = draft.RequiredQuestions?.ToList() ?? [],
```

**`UpdateAsync`**, junto a `course.Url = draft.Url;`:

```csharp
// null = la pantalla no las envió (por ejemplo, "Agregar grupo"): se dejan como están.
if (draft.RequiredQuestions is not null)
    course.CompletionRequiredQuestions = [.. draft.RequiredQuestions];
```

### `Repositories/CourseRepository.cs` ✏️ — `GetDetailAsync`

En el `Select` anónimo agrega `c.CompletionRequiredQuestions,` y en el `new CourseDetailDto { … }`:

```csharp
RequiredQuestions = row.CompletionRequiredQuestions,
```

---

## 7. Paso 5 — El formulario: leer y validar

### `Contracts/Persistence/ICourseCompletionRepository.cs` ✏️

**1. `RatingBucket`** lleva las dos escalas:

```csharp
public sealed record RatingBucket(int AssignmentId, byte Satisfaction, byte Usefulness, byte? KnowledgeBefore, byte? KnowledgeAfter, int Count);
```

**2. Dos métodos nuevos:**

```csharp
/// <summary>Preguntas obligatorias del curso. Vacía si el curso no existe o no tiene.</summary>
Task<IReadOnlyList<string>> GetRequiredQuestionsAsync(int courseId, CancellationToken ct);

/// <summary>Los comentarios más recientes del curso (anónimos).</summary>
Task<IReadOnlyList<string>> GetRatingCommentsAsync(int courseId, int take, CancellationToken ct);
```

### `Repositories/CourseCompletionRepository.cs` ✏️

**1. `GetRatingBucketsAsync`** agrupa también por las dos escalas:

```csharp
public Task<IReadOnlyList<RatingBucket>> GetRatingBucketsAsync(int courseId, CancellationToken ct) =>
    Guard<IReadOnlyList<RatingBucket>>(async () => await _context.Set<CourseRating>()
        .AsNoTracking()
        .Where(r => r.CourseId == courseId)
        .GroupBy(r => new { r.AssignmentId, r.Satisfaction, r.Usefulness, r.KnowledgeBefore, r.KnowledgeAfter })
        .Select(g => new RatingBucket(
            g.Key.AssignmentId, g.Key.Satisfaction, g.Key.Usefulness, g.Key.KnowledgeBefore, g.Key.KnowledgeAfter, g.Count()))
        .ToListAsync(ct));
```

**2. Los dos métodos nuevos:**

```csharp
public Task<IReadOnlyList<string>> GetRequiredQuestionsAsync(int courseId, CancellationToken ct) =>
    Guard<IReadOnlyList<string>>(async () => await _context.Set<Course>()
        .AsNoTracking()
        .Where(c => c.Id == courseId)
        .Select(c => c.CompletionRequiredQuestions)
        .FirstOrDefaultAsync(ct) ?? []);

public Task<IReadOnlyList<string>> GetRatingCommentsAsync(int courseId, int take, CancellationToken ct) =>
    Guard<IReadOnlyList<string>>(async () => await _context.Set<CourseRating>()
        .AsNoTracking()
        .Where(r => r.CourseId == courseId && r.Comments != null && r.Comments != "")
        .OrderByDescending(r => r.CreatedDate)
        .Take(take)
        .Select(r => r.Comments!)
        .ToListAsync(ct));
```

### `Helpers/CompletionAnswersValidator.cs`

```csharp
using DOCCB.Application.Features.Courses.Application.Constants;
using DOCCB.Application.Features.Courses.Application.DTOs;

namespace DOCCB.Application.Features.Courses.Application.Helpers
{
    /// <summary>Respuestas ya validadas y limpias, listas para guardar.</summary>
    public sealed record CompletionAnswers(byte Satisfaction, byte Usefulness, byte? KnowledgeBefore, byte? KnowledgeAfter, string? Comments);

    public static class CompletionAnswersValidator
    {
        /// <summary>Valida rangos y obligatorias. Devuelve las respuestas limpias o los errores.</summary>
        public static (CompletionAnswers? Answers, List<string> Errors) Validate(CompleteCourseRequestDto dto, IReadOnlyCollection<string> required)
        {
            var errors = new List<string>();
            bool IsRequired(string code) => required.Contains(code);

            var satisfaction = dto.Satisfaction ?? 0;
            var usefulness = dto.Usefulness ?? 0;
            if (satisfaction is < CompletionConstants.MinRating or > CompletionConstants.MaxRating
                || usefulness is < CompletionConstants.MinRating or > CompletionConstants.MaxRating)
            {
                errors.Add(CompletionConstants.StarsOutOfRange);
            }

            // 0 estrellas = sin calificar: no sirve para una pregunta obligatoria.
            if (IsRequired(CompletionQuestions.Quality) && satisfaction == 0) errors.Add(CompletionConstants.QualityRequired);
            if (IsRequired(CompletionQuestions.Usefulness) && usefulness == 0) errors.Add(CompletionConstants.UsefulnessRequired);

            if (dto.KnowledgeBefore is < CompletionConstants.MinKnowledge or > CompletionConstants.MaxKnowledge
                || dto.KnowledgeAfter is < CompletionConstants.MinKnowledge or > CompletionConstants.MaxKnowledge)
            {
                errors.Add(CompletionConstants.KnowledgeOutOfRange);
            }

            if (IsRequired(CompletionQuestions.KnowledgeBefore) && dto.KnowledgeBefore is null) errors.Add(CompletionConstants.KnowledgeBeforeRequired);
            if (IsRequired(CompletionQuestions.KnowledgeAfter) && dto.KnowledgeAfter is null) errors.Add(CompletionConstants.KnowledgeAfterRequired);

            var comments = dto.Comments?.Trim();
            if (string.IsNullOrEmpty(comments)) comments = null;
            if (comments?.Length > CompletionConstants.CommentsMaxLength) errors.Add(CompletionConstants.CommentsTooLong);
            if (IsRequired(CompletionQuestions.Comments) && comments is null) errors.Add(CompletionConstants.CommentsRequired);

            return errors.Count > 0
                ? (null, errors)
                : (new CompletionAnswers(
                    (byte)satisfaction,
                    (byte)usefulness,
                    (byte?)dto.KnowledgeBefore,
                    (byte?)dto.KnowledgeAfter,
                    comments), errors);
        }
    }
}
```

### `Services/CourseCompletionService.cs` ✏️

**1. `GetFormAsync`**, en el `new CompletionFormDto { … }`:

```csharp
RequiredQuestions = [.. await repository.GetRequiredQuestionsAsync(row.CourseId, ct)],
```

**2. `CompleteAsync`:** la validación ahora necesita las obligatorias del curso, así que va después de encontrar la asignación. Reemplaza el inicio y la creación de `rating`:

```csharp
public async Task<CourseResult<CompletionResultDto>> CompleteAsync(
    int assignmentUserId, CompleteCourseRequestDto dto, CurrentUserIdentity user, CancellationToken ct = default)
{
    var row = await FindOwnedAsync(assignmentUserId, user, ct);
    if (row is null) return CourseResult<CompletionResultDto>.Fail(CourseResultStatus.NotFound, CompletionConstants.FormNotFound);

    if (row.IsCompleted)
        return CourseResult<CompletionResultDto>.Fail(CourseResultStatus.Conflict, CompletionConstants.AlreadyCompleted);

    var required = await repository.GetRequiredQuestionsAsync(row.CourseId, ct);
    var (answers, errors) = CompletionAnswersValidator.Validate(dto, required);
    if (answers is null)
        return CourseResult<CompletionResultDto>.Fail(CourseResultStatus.Invalid, errors);

    // … la gerencia, `now` y `completion` quedan igual …

    var rating = new CourseRating
    {
        Id = Guid.NewGuid(),
        CourseId = row.CourseId,
        AssignmentId = row.AssignmentId,
        Satisfaction = answers.Satisfaction,
        Usefulness = answers.Usefulness,
        KnowledgeBefore = answers.KnowledgeBefore,
        KnowledgeAfter = answers.KnowledgeAfter,
        Comments = answers.Comments,
        CreatedDate = BusinessDate.Today(timeProvider), // solo la fecha
    };

    // … TryCompleteAsync y el resultado quedan igual …
}
```

Borra `IsValidRating`: ya no se usa.

**3. `GetProgressAsync`**, después de `progress.Ratings = RatingSummaryBuilder.Build(buckets, minimum);`:

```csharp
// Comentarios: solo del curso completo y solo si el resumen es visible (anonimato).
if (progress.Ratings.Visible)
{
    progress.Ratings.Comments = [.. await repository.GetRatingCommentsAsync(courseId, CompletionConstants.CommentsLimit, ct)];
}
```

---

## 8. Paso 6 — El resumen: promedios sin el 0

### `Helpers/RatingSummaryBuilder.cs` ✏️ — `Build` y `Average`

```csharp
public static RatingSummaryDto Build(IEnumerable<RatingBucket> buckets, int minimumResponses)
{
    var list = buckets.ToList();
    var responses = list.Sum(b => b.Count);

    // Con pocas respuestas un promedio puede delatar a alguien: solo se informa el conteo.
    if (responses < minimumResponses)
    {
        return new RatingSummaryDto { Responses = responses, Visible = false, MinimumResponses = minimumResponses };
    }

    // Índice = valor. El índice 0 cuenta a quienes no respondieron esa pregunta.
    var satisfaction = new int[CompletionConstants.MaxRating + 1];
    var usefulness = new int[CompletionConstants.MaxRating + 1];
    var knowledgeBefore = new int[CompletionConstants.MaxKnowledge + 1];
    var knowledgeAfter = new int[CompletionConstants.MaxKnowledge + 1];

    foreach (var bucket in list)
    {
        satisfaction[bucket.Satisfaction] += bucket.Count;
        usefulness[bucket.Usefulness] += bucket.Count;
        knowledgeBefore[bucket.KnowledgeBefore ?? 0] += bucket.Count;
        knowledgeAfter[bucket.KnowledgeAfter ?? 0] += bucket.Count;
    }

    return new RatingSummaryDto
    {
        Responses = responses,
        Visible = true,
        MinimumResponses = minimumResponses,
        SatisfactionAverage = Average(satisfaction),
        UsefulnessAverage = Average(usefulness),
        SatisfactionDistribution = satisfaction,
        UsefulnessDistribution = usefulness,
        KnowledgeBeforeAverage = Average(knowledgeBefore),
        KnowledgeAfterAverage = Average(knowledgeAfter),
        KnowledgeBeforeDistribution = knowledgeBefore,
        KnowledgeAfterDistribution = knowledgeAfter,
    };
}

/// <summary>Promedio sin el índice 0 (sin responder). null si nadie respondió esa pregunta.</summary>
private static double? Average(int[] buckets)
{
    var answered = buckets.Skip(1).Sum();
    return answered == 0
        ? null
        : Math.Round(buckets.Select((count, score) => count * score).Sum() / (double)answered, 1);
}
```

> `CanShowPerAssignment` no cambia: sigue contando formularios por asignación.
>
> **Reporte de resultados por correo** ([cursos-alertas-api.md](cursos-alertas-api.md)): su texto de calificaciones usa `SatisfactionAverage` y `UsefulnessAverage`, y ahora también muestra el conocimiento antes y después.

---

## 9. Contrato

**`GET /api/my-courses/{id}/completion-form`** agrega:

```json
{ "requiredQuestions": ["QUALITY", "KNOWLEDGE_AFTER"] }
```

**`POST /api/my-courses/{id}/complete`:**

```json
{ "satisfaction": 4, "usefulness": 0, "knowledgeBefore": 3, "knowledgeAfter": 8, "comments": "Muy buen curso." }
```

- Si falta una obligatoria, responde 400 con los mensajes, por ejemplo `["Elige tu nivel de conocimiento después de la capacitación (de 1 a 10)."]`.
- `usefulness: 0` es válido si la pregunta 2 no es obligatoria.

**`POST` y `PUT /api/courses`** aceptan `"requiredQuestions": [...]`. En el `PUT`, si no viene, no se cambia. **`GET /api/courses/{id}`** la devuelve.

**`GET /api/courses/{id}/assignments`** (resultados), en `ratings`:
- `knowledgeBeforeAverage` y `knowledgeAfterAverage`.
- Las dos distribuciones de 0 a 10.
- `comments` (solo en el resumen del curso).

---

## 10. Pruebas

- **Curso sin obligatorias:** enviar todo vacío (`{}`) finaliza el curso. La fila de `course_rating` queda con 0, 0, `NULL`, `NULL`, `NULL`.
- **Curso con `QUALITY` y `COMMENTS` obligatorias:**
  - `satisfaction: 0` → "Califica la calidad del espacio de formación…".
  - Comentarios en blanco (`"   "`) → "Escribe tus comentarios.".
  - Con los dos → finaliza.
- **Rangos:** `knowledgeBefore: 11` o `satisfaction: 6` → 400 con el mensaje de rango.
- **Comentario de 1.001 caracteres** → "Los comentarios pueden tener hasta 1.000 caracteres.".
- **Editor del curso:**
  - Guardar con `["QUALITY","FOO"]` → "Pregunta desconocida: FOO.".
  - Guardar con `["QUALITY"]` y luego "Agregar grupo" (sin `requiredQuestions`) → el curso sigue con `["QUALITY"]`.
- **Resultados con 3 respuestas** (estrellas 4, 0 y 5):
  - El promedio de calidad es 4,5 (el 0 no cuenta) y `satisfactionDistribution[0]` es 1.
  - Aparecen el conocimiento antes y después y los comentarios.
- **Resultados con 2 respuestas:** `visible: false`, sin promedios ni comentarios.

---

## ✅ Checklist

- [ ] `CursosFormularioPreguntas.sql`.
- [ ] `Course.CompletionRequiredQuestions` y `CourseRating` (3 propiedades), con sus configuraciones.
- [ ] `CompletionQuestions`, `CompletionConstants`.
- [ ] DTOs:
  - Formulario y respuestas.
  - `RatingSummaryDto`.
  - `SaveCourseRequestDto` y `CourseDetailDto`.
- [ ] `CourseValidationHelper` + `CourseDraft`.
- [ ] `CourseService`: crear y editar las obligatorias.
- [ ] `CourseRepository.GetDetailAsync`.
- [ ] `RatingBucket`, `GetRequiredQuestionsAsync`, `GetRatingCommentsAsync`.
- [ ] `CompletionAnswersValidator`.
- [ ] `CourseCompletionService`: el formulario, finalizar y los comentarios.
- [ ] `RatingSummaryBuilder`.

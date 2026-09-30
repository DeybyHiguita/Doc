# 📐 Referencia de estilos y capas de DOCCB

Lo que muestran las pantallas y la solución reales (fotos del 30 sep 2026): las páginas de **Grupos de usuarios**, **Nuevo grupo** y **Cursos**, y la solución `DOCCB` en Visual Studio.

Todas las guías nuevas deben seguir esto. Cuando una guía anterior no coincide, manda esta referencia.

---

## 1. 🗂️ Capas de la API

### Estructura real

```text
Solución "DOCCB" (4 proyectos)
└── Src/
    ├── Application/DOCCB.Application/
    │   ├── Common/
    │   ├── Contracts/Persistence/
    │   │   ├── DuplicateKeyException.cs
    │   │   ├── ICourseRepository.cs
    │   │   ├── IGenericRepository.cs
    │   │   ├── IUnitOfWork.cs
    │   │   ├── IUnitOfWorkFactory.cs
    │   │   ├── IUserGroupRepository.cs
    │   │   └── IUserSearchRepository.cs
    │   ├── EmailsTemplate/
    │   ├── Features/<Feature>/Application/…     Constants · DTOs · Helpers · Interfaces · Services
    │   │                                          (p. ej. UserGroupService.cs, UserGroupConstants.cs)
    │   ├── Helper/
    │   └── ApplicationServiceRegistration.cs
    ├── Domain/DOCCB.Domain/
    │   └── Entities/ · Enum/
    ├── Infraestructure/DOCCB.Infraestructure/
    │   ├── Common/GenericRepositoryBase.cs       ⭐ base de los repositorios
    │   ├── Configurations/<Entidad>Configuration.cs   (AlertConfiguration, AreaConfiguration…)
    │   ├── Persistence/
    │   │   ├── Models/                           DbContext
    │   │   └── Scripts SQL/                      scripts versionados
    │   ├── Repositories/
    │   │   ├── CourseRepository.cs
    │   │   ├── GenericRepository.cs
    │   │   ├── ScopedUnitOfWorkWrapper.cs
    │   │   ├── UnitOfWork.cs
    │   │   ├── UnitOfWorkFactory.cs
    │   │   ├── UserGroupRepository.cs
    │   │   └── UserSearchRepository.cs
    │   └── InfrastructureServiceRegistration.cs
    └── Presentation/                             WebApp (controladores)
```

### Reglas que salen de ahí

| Qué | Dónde |
|---|---|
| Interfaz de un repositorio | `DOCCB.Application/Contracts/Persistence/I<Nombre>Repository.cs` |
| Implementación | `DOCCB.Infraestructure/Repositories/<Nombre>Repository.cs` |
| Mapeo de EF | `DOCCB.Infraestructure/Configurations/<Entidad>Configuration.cs` |
| Tablas | `DOCCB.Infraestructure/Persistence/Scripts SQL/<Modulo>.sql` |
| Servicios, DTOs, constantes | `DOCCB.Application/Features/<Feature>/Application/…` |
| Registro | `ApplicationServiceRegistration.cs` (servicios) e `InfrastructureServiceRegistration.cs` (repositorios) |

### `GenericRepositoryBase<TContext, T>`

```csharp
public class GenericRepositoryBase<TContext, T> where TContext : DbContext where T : class
{
    protected readonly TContext _context;
    protected readonly DbSet<T> _dbSet;

    protected GenericRepositoryBase(TContext context) { … }

    public virtual async Task<T?> GetByIdAsync(object id)
    {
        try { return await _dbSet.FindAsync(id); }
        catch (DbUpdateException) { throw; }
        catch (SqlException) { throw; }
        catch (TimeoutException) { throw; }
        catch (Exception ex)
        {
            throw new InvalidOperationException($"Error en el repositorio para la entidad {typeof(T).Name}.", ex);
        }
    }
}
```

**Convención:** los errores de base de datos (`DbUpdateException`, `SqlException`, `TimeoutException`) suben tal cual. Cualquier otro se envuelve en `InvalidOperationException` con el nombre de la entidad.

Los repositorios propios de un módulo, como `CourseCompletionRepository`, **heredan de esta base**, usan `_context` y `_dbSet`, y aplican la misma convención.

### ⚠️ Dos observaciones sobre la base

1. **La cancelación termina envuelta.** `catch (Exception ex)` también atrapa `OperationCanceledException`, y la convierte en `InvalidOperationException`. Pasa, por ejemplo, cuando el usuario cierra la página y se cancela la petición: en los logs aparece como error del repositorio y el middleware puede responder 500. Conviene dejarla pasar antes del `catch` general:

   ```csharp
   catch (OperationCanceledException) { throw; }
   ```

2. **`GetByIdAsync` no recibe `CancellationToken`** y atrapa `DbUpdateException`, que solo ocurre al guardar. No rompe nada, pero si se toca la base es buen momento para agregar `CancellationToken ct = default` y pasarlo a `FindAsync(new[] { id }, ct)`.

---

## 2. 🎨 Estilos de las pantallas

### Lo que se ve

| Elemento | Cómo se ve |
|---|---|
| **Acento** | Dorado / mostaza. Es el color de marca de la app. |
| **Fuente** | Sans geométrica (tipo Montserrat): títulos en negrita, textos de apoyo en gris. |
| **Encabezado de página** | Título grande en negrita y un subtítulo gris. En Cursos va dentro de una tarjeta "hero" con un leve tinte dorado, un eyebrow en mayúsculas doradas ("COMPENSACIÓN Y BENEFICIOS") y el botón principal a la derecha. |
| **Botón principal** | Relleno dorado, texto oscuro, bordes redondeados, ícono a la izquierda ("+ Nuevo curso", "✓ Guardar grupo", "Nuevo grupo"). |
| **Botón secundario** | Borde gris, fondo blanco ("Cancelar"). |
| **Tarjetas** | Fondo blanco, radio grande, sombra muy suave, sin bordes marcados. |
| **Indicadores** | Tiles con un ícono en un cuadrado de color suave y el número grande en negrita (Total, Virtuales, Presenciales, ID externo pendiente). El seleccionado lleva un borde dorado. |
| **Barra de proporción** | Barra delgada dorada con una etiqueta a la derecha ("75 % virtual"). |
| **Buscador** | Input con lupa dentro, a lo ancho. |
| **Filtros rápidos** | Pastillas "Todas / Virtual / Presencial". La activa tiene fondo dorado suave. |
| **Filtro segmentado** | "Todos 0 · Maestro 0 · Solo directorio 0": el activo en oscuro y los demás con borde. |
| **Pestañas** | Pastillas ("Por líder / Buscar persona / Pegar correos"). La activa en dorado. |
| **Tablas** | Encabezado **dorado con texto oscuro** en mayúsculas pequeñas, filas blancas y acciones con íconos sueltos (editar ✎, eliminar 🗑). |
| **Paginación** | Centrada: `‹  Página 1 de 1  ›`. Flechas sin borde. |
| **Tarjeta de curso** | Distintivo de modalidad arriba a la izquierda (VIRTUAL en dorado, PRESENCIAL en verde) y acciones ✎ 🗑 a la derecha. Luego el nombre, el bloque de ID externo ("Vincular ID externo" con RECOMENDADO/OPCIONAL, o el ID con ✎) y un pie con "N usuarios". |
| **Carga** | Esqueletos grises con la forma de las tarjetas. |
| **Resumen lateral** | Tarjeta "TOTAL 0 personas" con puntos de color por fuente (verde maestro, dorado solo directorio). |

### Tokens

Todo sale de los tokens de cada feature (`--cu-*` en cursos, `--ug-*` en grupos), conectados a las variables de la app:

| Token | Valor en la app |
|---|---|
| `--cu-accent` / `--ug-accent` | dorado de marca |
| `--cu-on-accent` / `--ug-on-accent` | **texto oscuro** (sobre dorado, el blanco no se lee) |
| `--cu-onsite` | verde (Presencial, finalizado) |
| `--cu-virtual` | dorado |
| `--cu-surface` / `--cu-surface-alt` | blanco / gris muy claro |

> Agrega `--cu-on-accent` al bloque de tokens de cursos ([crud-cursos-angular.md](crud-cursos-angular.md), sección 4) si no está: `--cu-on-accent: var(--bs-emphasis-color);` o tu variable de texto oscuro. Las tablas nuevas de cursos lo usan en el encabezado.

### 🐛 Detalles que se ven en las fotos

| # | Dónde | Qué pasa | Corrección |
|---|---|---|---|
| 1 | Nuevo grupo → "Buscar equipos" | Es el único botón **azul** de Bootstrap (`btn-primary`), todo lo demás es dorado. | `btn-accent`. Ya está corregido en [grupos-usuarios-angular.md](grupos-usuarios-angular.md). |
| 2 | Nuevo grupo → "Todos los niveles" / "Incluir a los líderes" | Los interruptores se ven como un punto gris. El riel apagado casi no tiene contraste con el fondo. | Dale borde visible al interruptor y el acento cuando está activo (estilo en la guía de grupos). |
| 3 | Listado de grupos | Aparece una **barra de scroll vertical** dentro de la tabla con una sola fila. `overflow-x: auto` convierte `overflow-y` en `auto`, y la animación de entrada de las filas (`translateY`) desborda por un instante. | `overflow-y: hidden` en el contenedor de la tabla. |
| 4 | Listado de grupos | "Integrantes" alineado a la izquierda y "Líderes" centrado. El encabezado "Acciones" está centrado pero los íconos no. | Números y acciones centrados, encabezado y celda con la misma alineación. |
| 5 | Tarjeta de curso | El pie dice "0 usuarios". Con la asignación por grupos ese dato queda corto. | "N grupos · N personas" más el avance de finalización y la acción **Seguimiento** ([cursos-grupos-finalizacion-angular.md](cursos-grupos-finalizacion-angular.md)). |

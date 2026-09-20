"""Completa el catálogo español de Dran (priv/gettext/es/LC_MESSAGES/default.po).

Idempotente: para cada msgid presente en ES reescribe el msgstr con la
traducción curada y limpia el flag `fuzzy`. Los msgid que no están en ES se
dejan intactos.
"""
import re
import sys

PO = "priv/gettext/es/LC_MESSAGES/default.po"
EN = "priv/gettext/en/LC_MESSAGES/default.po"

ES = {
    "%{count} memories permanently deleted": "%{count} memorias borradas permanentemente",
    "%{count} memory facts": "%{count} hechos de memoria",
    '%{count} results for “%{query}” — search covers active facts.': '%{count} resultados para “%{query}” — la búsqueda cubre los hechos activos.',
    "%{count} table": ("%{count} tabla", "%{count} tablas"),
    "%{count} valid field": ("%{count} campo válido", "%{count} campos válidos"),
    "%{count} workspace": ("%{count} workspace", "%{count} workspaces"),
    "%{email} now has access to this workspace": "%{email} ya tiene acceso a este workspace",
    "%{percent}% used · %{total}": "%{percent}% usado · %{total}",
    "(blank = disabled)": "(vacío = deshabilitado)",
    "API admin token": "Token admin del API",
    "API key access updated": "Acceso de la clave API actualizado",
    "API keys": "Claves API",
    "API not configured": "API no configurada",
    "API unavailable — models cannot be listed. You can still write a manual override, or check DRAN_INFERENCE_API_URL.": "API no disponible — los modelos no pueden listarse. Aún puedes escribir un override manual, o revisa DRAN_INFERENCE_API_URL.",
    "Access": "Acceso",
    "Account menu": "Cuenta",
    "Account settings": "Ajustes de cuenta",
    "Active": "Activo",
    "Add a custom page type": "Añadir un tipo de página personalizado",
    "Add a user…": "Agregar un usuario…",
    "Add page type": "Añadir tipo de página",
    "Adding…": "Añadiendo…",
    "Admin: settings and members, plus content.": "Admin: ajustes y miembros, además del contenido.",
    "Advanced": "Avanzado",
    "Atomic facts shared by %{name}'s workers.": "Hechos atómicos compartidos por los workers de %{name}.",
    "Available types": "Tipos disponibles",
    "BEAM memory": "Memoria BEAM",
    "Body": "Cuerpo",
    "Clear": "Limpiar",
    "Clusters of related pages in your brain": "Clusters de páginas relacionadas en tu cerebro",
    "Collapse or expand the sidebar": "Contraer o expandir la barra lateral",
    "Color": "Color",
    "Configured": "Configurada",
    "Connection refused — the server is not responding": "Conexión rechazada — el servidor no responde",
    "Could not add the user": "No se pudo agregar al usuario",
    "Could not create the group.": "No se pudo crear el grupo.",
    "Could not delete the group.": "No se pudo eliminar el grupo.",
    "Could not rename the group.": "No se pudo renombrar el grupo.",
    "Could not save settings": "No se pudieron guardar los ajustes",
    "Could not save the page type": "No se pudo guardar el tipo de página",
    "Could not save the preference": "No se pudo guardar la preferencia",
    "Could not share.": "No se pudo compartir.",
    "Could not update the access": "No se pudo actualizar el acceso",
    "Create some pages to see your brain's trajectory.": "Crea algunas páginas para ver la trayectoria de tu cerebro.",
    "Curated and smart page lists that update as the workspace changes.": "Listas de páginas curadas e inteligentes que se actualizan a medida que cambia el workspace.",
    "Database": "Base de datos",
    "Date + URL": "Fecha + URL",
    "Delete permanently": "Borrar permanentemente",
    "Delete stale": "Borrar obsoletos",
    "Delete this group? Its shares are removed too.": "¿Eliminar este grupo? Sus comparticiones también se eliminan.",
    "Delete this key permanently?": "¿Eliminar esta clave permanentemente?",
    "Details": "Detalles",
    "Disabled": "Desactivado",
    "Disk": "Disco",
    "Domain not resolved": "Dominio no resuelto",
    "Each key carries its own name — that name is the agent identity used to attribute what it writes — plus its own workspace access matrix (read, or read + write).": "Cada clave lleva su propio nombre — ese nombre es la identidad del agente usada para atribuir lo que escribe — además de su propia matriz de acceso por workspace (lectura, o lectura + escritura).",
    "Editor": "Editor",
    "Editor: create and edit pages, no access to settings.": "Editor: crea y edita páginas, sin acceso a los ajustes.",
    "Effective model for chat and workers. Configure in Admin → Models.": "Modelo efectivo para chat y workers. Configúralo en Admin → Modelos.",
    "Effective model for embeddings. Configure in Admin → Models.": "Modelo efectivo para embeddings. Configúralo en Admin → Modelos.",
    "Empty is fine — the type simply gets no extra fields.": "Vacío está bien — el tipo simplemente no tendrá campos extra.",
    "Enabled": "Activado",
    "English is the default. Your choice is saved to your account and applies to every workspace.": "El inglés es el idioma por defecto. Tu elección se guarda en tu cuenta y aplica a todos los workspaces.",
    "Enter a new password": "Ingresa una nueva contraseña",
    "Enter your current password": "Ingresa tu contraseña actual",
    "Extra fields the editor renders for this type. One JSON array per field: [type, key, label] with type one of %{types}.": "Campos extra que el editor renderiza para este tipo. Un array JSON por campo: [tipo, clave, etiqueta], con tipo uno de %{types}.",
    "Features": "Funcionalidades",
    "Field %{index}: the key must be a non-empty string.": "Campo %{index}: la clave debe ser una cadena no vacía.",
    "Field %{index}: the label must be a non-empty string.": "Campo %{index}: la etiqueta debe ser una cadena no vacía.",
    "Field %{index}: unknown type %{type}. Allowed types: %{allowed}.": "Campo %{index}: tipo desconocido %{type}. Tipos admitidos: %{allowed}.",
    "Filter by status": "Filtrar por estado",
    "Full-text and semantic search across this workspace's pages.": "Búsqueda de texto completo y semántica en las páginas de este workspace.",
    "Generate token": "Generar token",
    "Generated": "Generada",
    "Generated reports written from this workspace's content.": "Informes generados a partir del contenido de este workspace.",
    "Gets its own sidebar section, list, graph colour and editor fields. The four built-in types cannot be redefined.": "Tendrá su propia sección en la barra lateral, su lista, su color en el grafo y sus campos de editor. Los cuatro tipos integrados no se pueden redefinir.",
    "Give an existing account access to this workspace. People must already have a Dran account — there is no invitation email, access is granted as soon as you add them.": "Da acceso a este workspace a una cuenta existente. La persona ya debe tener una cuenta de Dran — no hay correo de invitación: el acceso se concede en cuanto la agregas.",
    "Group": "Grupo",
    "Group created.": "Grupo creado.",
    "Group deleted — its shares were removed too.": "Grupo eliminado — sus comparticiones también se eliminaron.",
    "Groups": "Grupos",
    "Growth of your second brain over time": "Crecimiento de tu segundo cerebro en el tiempo",
    "Helpful (+0.05 trust)": "Útil (+0.05 trust)",
    "Helpful feedback received": "Feedback útil recibido",
    "Heroicons name. The “hero-” prefix is added automatically.": "Nombre de Heroicons. El prefijo “hero-” se añade automáticamente.",
    "Hex colour for the graph node, the legend and the type dot.": "Color hex para el nodo del grafo, la leyenda y el punto del tipo.",
    "Home": "Inicio",
    "Icon": "Icono",
    "Identifier used by the API and by filters. Lowercase letters, digits, “_” or “-”.": "Identificador usado por el API y por los filtros. Minúsculas, dígitos, “_” o “-”.",
    "Identity": "Identidad",
    "Instance": "Instancia",
    "Instance configuration saved.": "Configuración de instancia guardada.",
    "Instance settings": "Configuración de la instancia",
    "Interface language for your account.": "Idioma de la interfaz para tu cuenta.",
    "Invalid JSON: %{detail}": "JSON inválido: %{detail}",
    "Item visibility": "Visibilidad del elemento",
    "Job failed: %{label}": "Job falló: %{label}",
    "LLM, embeddings": "LLM, embeddings",
    "Label": "Etiqueta",
    "Language": "Idioma",
    "Language updated": "Idioma actualizado",
    "Last run": "Último run",
    "Leave it empty to keep the current one. Set it to give access back to an account that cannot sign in.": "Déjala vacía para conservar la actual. Escríbela para devolver el acceso a una cuenta que no puede iniciar sesión.",
    "Legacy API admin token for instance-wide agent access.": "Token de admin del API (heredado) para acceso de agentes a toda la instancia.",
    "Legacy bearer for the API with full-owner access. Blank = disabled; per-user tokens keep working.": "Bearer legacy para el API con acceso full-owner. Vacío = deshabilitado; los tokens por usuario siguen funcionando.",
    "Load an example:": "Cargar un ejemplo:",
    "Log of the recent changes to this workspace's pages.": "Registro de los cambios recientes en las páginas de este workspace.",
    "Log out": "Cerrar sesión",
    "Mark as stale": "Marcar como obsoleto",
    "Members of": "Miembros de",
    "Membership updated": "Membresía actualizada",
    "Memory": "Memoria",
    "Memory not found": "Memoria no encontrada",
    "Memory scope": "Alcance de la memoria",
    "Menu": "Menú",
    "Meta fields": "Campos de metadatos",
    "Meta fields must be a JSON array of fields.": "Los campos de metadatos deben ser un array JSON de campos.",
    "Minimum 8 characters. Share it with them: it is how they sign in.": "Mínimo 8 caracteres. Compártela con la persona: es con ella que inicia sesión.",
    "Monitoring, instance configuration and environment.": "Monitoreo, configuración de instancia y entorno.",
    "Name is required.": "El nombre es obligatorio.",
    "Named lists of users used as share targets.": "Listas con nombre de usuarios que se usan como destino al compartir.",
    "Never": "Nunca",
    "New %{type}": "Nueva %{type}",
    "New API key": "Nueva clave API",
    "New Page": "Nueva página",
    "New group name…": "Nombre del grupo nuevo…",
    "New type": "Tipo nuevo",
    "No API keys yet — create one to give an agent access to your workspaces.": "Aún no hay claves API — crea una para dar a un agente acceso a tus workspaces.",
    "No account with that email exists on this instance. Only existing users can be added.": "No existe ninguna cuenta con ese correo en esta instancia. Solo se pueden agregar usuarios existentes.",
    "No groups yet — create one to share with several people at once.": "Aún no hay grupos — crea uno para compartir con varias personas a la vez.",
    "No instance": "Sin instancia",
    "No members yet.": "Aún no hay miembros.",
    "No memories": "Sin memorias",
    "No pages start with this letter.": "Ninguna página empieza por esta letra.",
    "No plan": "Sin plan",
    "No project": "Sin proyecto",
    "No stale memories to delete": "No hay memorias obsoletas que borrar",
    "No users have access to this workspace yet.": "Todavía no hay usuarios con acceso a este workspace.",
    "None": "Ninguno",
    "Not authorized.": "No autorizado.",
    "Not configured": "No configurada",
    "Not helpful (−0.10 trust)": "No útil (−0.10 trust)",
    "Not shared with anyone yet.": "Todavía no se ha compartido con nadie.",
    "Offline": "Sin conexión",
    "Only mine": "Solo míos",
    "Only the people you add from the Users tab can open this workspace, and it never appears in anyone else's list. There is no public, discoverable tier.": "Solo las personas que agregues desde la pestaña Usuarios pueden abrir este workspace, y nunca aparece en la lista de nadie más. No hay un nivel público ni descubrible.",
    "Owner: settings, members and content.": "Owner: ajustes, miembros y contenido.",
    "Page type added": "Tipo de página añadido",
    "Page type removed": "Tipo de página eliminado",
    "Peak pages": "Páginas pico",
    "Peak period": "Período pico",
    "Permanent deletion — cannot be undone": "Borrado permanente — no se puede deshacer",
    "Permanently delete ALL stale memories?": "¿Borrar permanentemente TODAS las memorias obsoletas?",
    "Permanently delete this memory? This cannot be undone.": "¿Borrar permanentemente esta memoria? No se puede deshacer.",
    "Personal keys for the Dran REST API.": "Claves personales para el API REST de Dran.",
    "Plural": "Plural",
    "Plural name, used for lists and counters.": "Nombre en plural, usado en listas y contadores.",
    "Presentation": "Presentación",
    "Preview": "Vista previa",
    "Private: only you. Public: everyone on this instance. Shared: only the people you invite.": "Privado: solo tú. Público: todo el mundo en esta instancia. Compartido: solo las personas que invites.",
    "R/O": "R/O",
    "R/W": "R/W",
    "Read access only — editing stays with the owner.": "Solo lectura — la edición queda en manos del propietario.",
    "Refresh": "Actualizar",
    "Related facts derived automatically (semantic)": "Hechos relacionados derivados automáticamente (semantic)",
    "Related pages grouped into themes by the nightly job.": "Páginas relacionadas agrupadas en temas por el job nocturno.",
    "Related:": "Relacionados:",
    "Remove": "Quitar",
    "Remove %{user} from this workspace?": "¿Quitar a %{user} de este workspace?",
    "Remove from workspace": "Quitar del workspace",
    "Remove the “%{label}” page type? Its pages are kept, but they lose their section and list.": "¿Quitar el tipo de página “%{label}”? Sus páginas se conservan, pero pierden su sección y su lista.",
    "Restore": "Restaurar",
    "Results for": "Resultados para",
    "Revoke this grant": "Revocar este acceso",
    "Revoked": "Revocada",
    "Role": "Rol",
    "Saved queries that auto-update as your brain changes": "Consultas guardadas que se actualizan solas a medida que tu cerebro cambia",
    "Search users by email or name...": "Buscar usuarios por email o nombre...",
    "Search worker memory...": "Buscar en la memoria de los workers...",
    "Select a model": "Selecciona un modelo",
    "Select models for chat and embeddings.": "Selecciona modelos para chat y embeddings.",
    "Share": "Compartir",
    "Share content with several people at once — a group is a list of users used as a share target.": "Comparte contenido con varias personas a la vez — un grupo es una lista de usuarios que se usa como destino al compartir.",
    "Share memory between workspace users": "Compartir memoria entre los usuarios del workspace",
    "Share pages between workspace users": "Compartir páginas entre los usuarios del workspace",
    "Share read access": "Compartir lectura",
    "Share this page with other users or groups": "Comparte esta página con otros usuarios o grupos",
    "Share with a group…": "Compartir con un grupo…",
    "Share with a user…": "Compartir con un usuario…",
    "Shared": "Compartido",
    "Shared with": "Compartido con",
    "Shared.": "Compartido.",
    "Showing only your memories": "Mostrando solo tus memorias",
    "Showing the whole workspace": "Mostrando todo el workspace",
    "Shown in the workspace switcher, the sidebar and every breadcrumb.": "Se muestra en el selector de workspaces, la barra lateral y las migas de pan.",
    "Singular name, used in the sidebar and on buttons.": "Nombre en singular, usado en la barra lateral y en los botones.",
    "Slug": "Slug",
    "Stale": "Obsoletos",
    "Stop impersonating": "Dejar de impersonar",
    "Switch to read + write": "Cambiar a lectura + escritura",
    "Switch to read only": "Cambiar a solo lectura",
    "Test": "Probar",
    "Test connection": "Probar conexión",
    "Testing...": "Probando...",
    "Text field": "Campo de texto",
    "That user already has access to this workspace.": "Ese usuario ya tiene acceso a este workspace.",
    "The current password is incorrect": "La contraseña actual es incorrecta",
    "The key name is required": "El nombre de la clave es obligatorio",
    "The key name is the agent identity: content written with this key is attributed to this name unless the client sends an X-Hermes-Agent header.": "El nombre de la clave es la identidad del agente: el contenido escrito con esta clave se atribuye a este nombre salvo que el cliente envíe una cabecera X-Hermes-Agent.",
    "The relationship map of this workspace's pages.": "El mapa de relaciones de las páginas de este workspace.",
    "The workspace identifier in every URL: /%{slug}/notes, /%{slug}/settings…": "El identificador del workspace en cada URL: /%{slug}/notes, /%{slug}/settings…",
    "This account can open the instance": "Esta cuenta puede abrir la instancia",
    "Timeline of how this workspace's knowledge grew over time.": "Línea temporal de cómo creció el conocimiento de este workspace.",
    "Timeout — the server took too long": "Timeout — el servidor tardó demasiado",
    "Token generated and copied to the clipboard.": "Token generado y copiado al portapapeles.",
    "Top pages": "Páginas principales",
    "Total pages": "Total de páginas",
    "Trajectory": "Trayectoria",
    "Trust score": "Puntuación de confianza",
    "Turn parts of this workspace on or off. Disabling a feature only removes its entry point — no page, relation or summary is ever deleted.": "Activa o desactiva partes de este workspace. Desactivar una funcionalidad solo quita su punto de entrada: nunca se borra ninguna página, relación o resumen.",
    "URL path": "Ruta URL",
    "URL segment — pages will live at /workspace/%{path}/slug. Must be unique and cannot collide with a reserved route.": "Segmento de URL — las páginas vivirán en /workspace/%{path}/slug. Debe ser único y no puede chocar con una ruta reservada.",
    "Uptime": "Tiempo activo",
    "User": "Usuario",
    "Viewer": "Lector",
    "Viewer: read pages only.": "Viewer: solo lectura de páginas.",
    "What this workspace is called and who can reach it.": "Cómo se llama este workspace y quién puede acceder a él.",
    "When disabled, each user (and their agents) only sees the facts that belong to them; workspace owners and admins keep the full view.": "Si se desactiva, cada usuario (y sus agentes) ve solo los hechos que le pertenecen; owner y admin del workspace conservan la vista completa.",
    "When disabled, each user only sees the pages that belong to them; the graph only draws visible nodes and edges.": "Si se desactiva, cada usuario ve solo las páginas que le pertenecen; el grafo solo pinta nodos y aristas visibles.",
    "Which kinds of page this workspace can hold, and which of them are enabled.": "Qué tipos de página puede contener este workspace y cuáles están activados.",
    "Who can open this workspace, and with which role.": "Quién puede abrir este workspace y con qué rol.",
    "Worker memory": "Memoria de workers",
    "Workers store facts here through the /api/memory API; they appear live.": "Los workers almacenan hechos aquí vía la API /api/memory; aparecerán en vivo.",
    "Workspace not found.": "Workspace no encontrado.",
    "You are impersonating": "Estás impersonando a",
    "You are not a member of any workspace yet.": "Aún no eres miembro de ningún workspace.",
    "You can only grant access to your own workspaces": "Solo puedes dar acceso a tus propios workspaces",
    "Your profile, password and connected accounts.": "Tu perfil, tu contraseña y las cuentas conectadas.",
    "active": "activos",
    "custom": "personalizado",
    "members": "miembros",
    "more": "más",
    "optional": "opcional",
    "page": ("página", "páginas"),
    "read-only": "Solo lectura",
    "score": "puntuación",
    "this workspace": "este workspace",
}

STR = re.compile(r'"((?:[^"\\]|\\.)*)"')


def esc(s: str) -> str:
    # A Spanish *value* never contains a literal backslash: if one shows up it
    # means the value was written pre-escaped in ES, which would double-escape
    # and produce an unparseable PO file. Fail loudly instead.
    if "\\" in s:
        raise SystemExit(f"ES value contains a backslash (write it unescaped): {s!r}")
    return s.replace('"', '\\"').replace("\n", "\\n")


def msgid_of(block: str):
    m = re.search(r"^msgid ((?:\"(?:[^\"\\]|\\.)*\"\s*)+)", block, re.M)
    if not m:
        return None
    return "".join(STR.findall(m.group(1)))


def main() -> int:
    txt = open(PO, encoding="utf-8").read()
    blocks = txt.split("\n\n")
    touched = 0
    untranslated = []

    for i, b in enumerate(blocks):
        msgid = msgid_of(b)
        if msgid is None or msgid == "":
            continue

        value = ES.get(msgid)

        if value is not None and "msgid_plural" in b:
            if isinstance(value, tuple):
                # Matches the whole msgstr line plus any continuation lines. The
                # generated value is always single-line, so eating the full line
                # is both simpler and safer than balancing quotes (a previously
                # double-escaped entry leaves trailing junk that a balanced
                # match would not consume).
                b = re.sub(r'^msgstr\[0\] [^\n]*(?:\n"[^\n]*)*', f'msgstr[0] "{esc(value[0])}"', b, flags=re.M)
                b = re.sub(r'^msgstr\[1\] [^\n]*(?:\n"[^\n]*)*', f'msgstr[1] "{esc(value[1])}"', b, flags=re.M)
                touched += 1
        elif isinstance(value, str):
            b = re.sub(r'^msgstr [^\n]*(?:\n"[^\n]*)*', f'msgstr "{esc(value)}"', b, flags=re.M)
            touched += 1

        # ALWAYS clear the fuzzy flag, even for entries the dictionary does not
        # cover: Gettext ignores a fuzzy translation, so leaving one behind means
        # the page falls back to English while the file *looks* translated — and
        # the msgstr a merge leaves there is a fuzzy match against an unrelated
        # entry ("Editor" -> "Editar", "Viewer" -> "Ver"), i.e. plain wrong.
        b = re.sub(r"^#, (.*?), fuzzy$", r"#, \1", b, flags=re.M)
        b = re.sub(r"^#, (.*?)fuzzy, ?", r"#, \1", b, flags=re.M)
        b = re.sub(r"^#, fuzzy\n", "", b, flags=re.M)

        if value is None and is_untranslated(b):
            untranslated.append(msgid)

        blocks[i] = b

    open(PO, "w", encoding="utf-8").write("\n\n".join(blocks))
    print(f"es: translations written: {touched}")

    if untranslated:
        print(f"es: {len(untranslated)} msgid(s) have NO translation — add them to ES:")
        for msgid in sorted(untranslated):
            print(f"  * {msgid!r}")
        return 1

    print(f"en: {clear_identity_catalog()}")
    return 0


def is_untranslated(block: str) -> bool:
    """True when every msgstr of the entry is empty (singular or plural)."""
    values = re.findall(r'^msgstr(?:\[\d\])? "((?:[^"\\]|\\.)*)"$', block, re.M)
    return bool(values) and all(not v.strip() for v in values)


def clear_identity_catalog() -> str:
    """
    Normaliza el catálogo inglés a una identidad pura.

    El inglés ES el idioma fuente: sus `msgid` ya son el texto que se muestra,
    así que cualquier `msgstr` sobrante — o un `fuzzy` heredado de cuando el
    español era el idioma por defecto — es basura que hay que vaciar. Gettext
    cae al `msgid` cuando el `msgstr` está vacío, que es exactamente lo que
    queremos.
    """
    txt = open(EN, encoding="utf-8").read()
    blocks = txt.split("\n\n")
    cleaned = 0

    for i, b in enumerate(blocks):
        if msgid_of(b) in (None, ""):
            continue
        original = b

        b = re.sub(r'^msgstr\[\d\] (?:"(?:[^"\\]|\\.)*"(?:\n"(?:[^"\\]|\\.)*")*)', 'msgstr[0] ""', b, flags=re.M)
        b = re.sub(r'^msgstr (?:"(?:[^"\\]|\\.)*"(?:\n"(?:[^"\\]|\\.)*")*)', 'msgstr ""', b, flags=re.M)
        b = re.sub(r"^#, (.*?), fuzzy$", r"#, \1", b, flags=re.M)
        b = re.sub(r"^#, (.*?)fuzzy, ?", r"#, \1", b, flags=re.M)
        b = re.sub(r"^#, fuzzy\n", "", b, flags=re.M)

        # A plural entry must keep one msgstr per plural form (en: two).
        if "msgid_plural" in b:
            b = re.sub(
                r'(msgid_plural (?:"(?:[^"\\]|\\.)*"(?:\n"(?:[^"\\]|\\.)*")*)\n)(?:msgstr\[\d\] ""\n)+',
                r'\1msgstr[0] ""\nmsgstr[1] ""\n',
                b,
            )

        blocks[i] = b
        if b != original:
            cleaned += 1

    open(EN, "w", encoding="utf-8").write("\n\n".join(blocks))
    return f"{cleaned} entries emptied"


if __name__ == "__main__":
    sys.exit(main())

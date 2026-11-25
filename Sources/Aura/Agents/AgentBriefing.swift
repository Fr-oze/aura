import Foundation

/// Ce qu'il faut dire aux agents pour qu'ils se servent d'Aura. Un agent ne découvre jamais
/// une commande tout seul : tant que ce texte n'est pas dans ses consignes, la question dans
/// l'encoche reste une fonction morte.
///
/// Ce texte est la source unique : les réglages le montrent et le copient, le README le reprend.
enum AgentBriefing {

    /// Chemin de la commande installée par Aura.
    static var commandPath: String { "~/.aura/bin/aura" }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: HookInstaller.commandURL.path)
    }

    /// Exemple à coller dans un terminal pour essayer.
    static let example = #"~/.aura/bin/aura ask "On part sur quelle option ?" --choix "Refaire,Garder""#

    /// Bloc à coller dans les consignes de l'agent (CLAUDE.md, AGENTS.md, règle Cursor…).
    static let instructions = """
    ## Poser une question dans l'encoche (Aura)

    Quand une décision m'appartient et que tu ne peux pas trancher seul, ne devine pas et ne reste \
    pas bloqué dans ton terminal : pose la question dans l'encoche de mon Mac. Je réponds d'un clic, \
    sans ouvrir ton application.

    ```bash
    ~/.aura/bin/aura ask "On part sur quelle option ?" --choix "Refaire,Garder"
    ~/.aura/bin/aura ask "Quel nom pour la branche ?" --texte
    ~/.aura/bin/aura ask "Quel fichier je dois lire ?" --fichier
    ~/.aura/bin/aura ask "Je pousse ?" --choix "Oui,Non" --detail "3 commits sur main" --delai 300
    ```

    - La réponse sort sur la sortie standard. Code 0 : j'ai répondu. Code 1 : annulé ou délai \
    dépassé, applique la solution la plus prudente et dis-le. Code 2 : Aura ne tourne pas, continue \
    comme avant et demande-moi dans le chat.
    - Sans `--choix`, `--texte` ni `--fichier`, la question propose Oui / Non. `--delai` est en \
    secondes (180 par défaut).
    - Toujours le chemin complet `~/.aura/bin/aura` : la commande n'est pas forcément dans le `PATH`.
    - Ne mets pas « Annuler » dans les choix : `esc` annule déjà, et la commande sort en code 1.

    Quand tu reçois la réponse, recopie-la telle quelle dans ton message suivant (« Tu as répondu : \
    … ») avant d'agir. Sinon elle n'existe que dans ton terminal : moi, dans la conversation, je n'ai \
    aucune trace de ce que j'ai choisi.

    Quand t'en servir : un choix d'approche qui engage la suite, un accord avant d'envoyer ou de \
    publier quelque chose, une information que je suis seul à avoir. Pas pour une question de \
    confort, pas pour faire valider une étape évidente, jamais deux fois la même question.
    """
}

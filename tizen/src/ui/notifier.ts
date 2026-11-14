/** Something that tells its listeners when it changes (Flutter's ChangeNotifier). */
export class Notifier {
  private listeners = new Set<() => void>();

  listen(l: () => void): () => void {
    this.listeners.add(l);
    return () => this.listeners.delete(l);
  }

  protected notify(): void {
    this.listeners.forEach((l) => l());
  }
}

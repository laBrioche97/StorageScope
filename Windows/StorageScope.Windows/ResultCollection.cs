using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;

namespace StorageScope.Windows;

// One reset prevents WPF from sorting and rebuilding groups for every added file.
internal sealed class ResultCollection<T> : ObservableCollection<T>
{
    public void ReplaceAll(IEnumerable<T> values)
    {
        var replacement = values.ToArray();
        CheckReentrancy();
        Items.Clear();
        foreach (var value in replacement) Items.Add(value);
        OnPropertyChanged(new PropertyChangedEventArgs(nameof(Count)));
        OnPropertyChanged(new PropertyChangedEventArgs("Item[]"));
        OnCollectionChanged(new NotifyCollectionChangedEventArgs(NotifyCollectionChangedAction.Reset));
    }
}
